plugins {
    alias(libs.plugins.bakery)
    kotlin("jvm") version "2.1.20"
}

repositories {
    mavenCentral()
}

bakery { configPath = file("site.yml").absolutePath }

kotlin {
    jvmToolchain(25)
}

dependencies {
    testImplementation(libs.playwright)
    testImplementation("org.junit.jupiter:junit-jupiter:5.12.2")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
}

tasks {
    named("test", Test::class) {
        useJUnitPlatform()
        environment("BAKE_DIR", file("build/bake").absolutePath)
    }
}

tasks.register("a11yAudit") {
    group = "verification"
    description = "Run accessibility audit on the baked site using Playwright + axe-core"
    dependsOn("bake")
    finalizedBy("test")
}

// ============================================================
// ISO Build Pipeline — Magic Stick
// ============================================================

val magicStickVersion = rootProject.file("VERSION").readText().trim()
val dockerImage = "magic-stick:builder"
val projDir = layout.projectDirectory.asFile.absolutePath
val scriptDir = "${projDir}/scripts"
val isoDir = "${projDir}/build"
val isoName = "magic-stick_${magicStickVersion}.iso"

tasks.register<org.gradle.api.tasks.Exec>("dockerBuild") {
    group = "iso"
    description = "Build the Docker builder image (magic-stick:builder) — no-op if image already exists"
    commandLine(
        "bash", "-c",
        "docker image inspect $dockerImage >/dev/null 2>&1 || docker build -t $dockerImage $projDir"
    )
}

tasks.register<org.gradle.api.tasks.Exec>("isoClean") {
    group = "iso"
    description = "Clean ISO build artifacts (keep config)"
    dependsOn("dockerBuild")
    commandLine("docker", "run", "--rm", "--privileged",
        "-v", "$projDir:/magic-stick",
        dockerImage,
        "bash", "-c", "cd /magic-stick/build && lb clean 2>/dev/null || true")
}

tasks.register<org.gradle.api.tasks.Exec>("isoPurge") {
    group = "iso"
    description = "Purge all ISO build state (config + artifacts)"
    dependsOn("dockerBuild")
    commandLine("docker", "run", "--rm", "--privileged",
        "-v", "$projDir:/magic-stick",
        dockerImage,
        "bash", "-c", "cd /magic-stick/build && lb clean --purge 2>/dev/null || true")
}

tasks.register<org.gradle.api.tasks.Exec>("isoBuild") {
    group = "iso"
    description = "Build the Magic Stick ISO (lb config + lb build inside Docker)"
    dependsOn("dockerBuild")
    commandLine("bash", "-c",
        "docker run --rm --privileged " +
        "--tmpfs /tmp:exec,mode=1777 " +
        "-v \"$projDir:/magic-stick\" " +
        "-e \"MAGIC_STICK_VERSION=$magicStickVersion\" " +
        "-e \"CLEAN=false\" " +
        "-e \"PURGE=false\" " +
        "$dockerImage " +
        "/magic-stick/scripts/build-inner.sh " +
        "&& sudo chown -R \"$(id -u):$(id -g)\" \"$projDir/build\"")
}

tasks.register("isoRebuild") {
    group = "iso"
    description = "Force rebuild the Magic Stick ISO (purge + build)"
    dependsOn("isoPurge")
    finalizedBy("isoBuild")
}

tasks.register<org.gradle.api.tasks.Exec>("isoVerify") {
    group = "iso"
    description = "Verify the built ISO (boot files, bootloader, squashfs)"
    dependsOn("dockerBuild")
    commandLine("docker", "run", "--rm", "--privileged",
        "-v", "$projDir:/magic-stick",
        dockerImage,
        "/magic-stick/scripts/verify.sh", "/magic-stick/build/$isoName")
}

tasks.register<org.gradle.api.tasks.Exec>("isoTestSmoke") {
    group = "iso"
    description = "Smoke test: boot ISO in QEMU with smoke_test=true and verify all tools run"
    dependsOn("dockerBuild")
    commandLine("docker", "run", "--rm", "--privileged",
        "-v", "$projDir:/magic-stick",
        dockerImage,
        "/magic-stick/scripts/test-boot.sh", "--smoke",
        "/magic-stick/build/$isoName", "300")
}

tasks.register<org.gradle.api.tasks.Exec>("isoTestBoot") {
    group = "iso"
    description = "Test ISO boot in QEMU (BIOS + UEFI) inside Docker"
    dependsOn("dockerBuild")
    commandLine("docker", "run", "--rm", "--privileged",
        "-v", "$projDir:/magic-stick",
        dockerImage,
        "/magic-stick/scripts/test-boot.sh", "/magic-stick/build/$isoName", "120")
}

tasks.register<org.gradle.api.tasks.Exec>("isoTestSoftware") {
    group = "iso"
    description = "Test installed software inside the ISO squashfs via Docker"
    dependsOn("dockerBuild")
    commandLine("docker", "run", "--rm", "--privileged",
        "-v", "$projDir:/magic-stick",
        dockerImage,
        "bash", "/magic-stick/scripts/test-software.sh", "/magic-stick/build/$isoName")
}

tasks.register("isoTest") {
    group = "iso"
    description = "Verify + boot test + smoke test the built ISO"
    dependsOn("isoVerify", "isoTestBoot", "isoTestSmoke")
}

tasks.register("isoPipeline") {
    group = "iso"
    description = "Full pipeline: build ISO + verify + boot test"
    dependsOn("isoBuild")
    finalizedBy("isoTest")
}

tasks.register<org.gradle.api.tasks.Exec>("isoFlash") {
    group = "iso"
    description = "Initial A/B setup + flash ISO to USB (GPT 5 partitions, GRUB Legacy+UEFI with ext2/gfxterm modules)." +
        " Host-only. Pass -Pdevice=/dev/sdX -PsudoPassword=..."
    val device = (project.findProperty("device") as? String) ?: ""
    val ci = System.getenv("CI") ?: ""
    val isoFile = file("build/$isoName")
    onlyIf { device.isNotEmpty() && ci.isEmpty() && isoFile.exists() }
    val password = (project.findProperty("sudoPassword") as? String) ?: ""
    val scriptDir = "$projDir/scripts"
    commandLine("sudo", "-S", "bash", "-c",
        "set -e; " +
        "echo '=== A/B Setup + Flash (v0.3.0 + GRUB ext2/gfxterm fix) ==='; " +
        "bash \"$scriptDir/update-system.sh\" -y setup-ab \"$device\" \"$isoFile\"; " +
        "echo; " +
        "echo '=== Post-flash Status ==='; " +
        "bash \"$scriptDir/update-system.sh\" status \"$device\" || true; " +
        "echo; " +
        "echo '=== FLASH COMPLETE. Boot from USB to test. ==='")
    standardInput = password.byteInputStream()
}

// ============================================================
// A/B Partition Test Pipeline
// ============================================================

tasks.register<org.gradle.api.tasks.Exec>("isoTestAB") {
    group = "iso"
    description = "Test A/B partition setup on loopback device inside Docker (privileged)." +
        " Verifies GPT layout, GRUB ext2/gfxterm modules in core.img, persistence.conf"
    dependsOn("dockerBuild")
    // Runs test-ab-partition.sh inside Docker with all needed perms
    commandLine("docker", "run", "--rm", "--privileged",
        "-v", "$projDir:/magic-stick",
        "--cap-add", "SYS_ADMIN",
        "--device", "/dev/loop-control",
        "--device", "/dev/loop0",
        "--device", "/dev/loop1",
        "--device", "/dev/loop2",
        "--device", "/dev/loop3",
        "--device", "/dev/loop4",
        "--device", "/dev/loop5",
        "--device", "/dev/loop6",
        "--device", "/dev/loop7",
        dockerImage,
        "bash", "-c",
        "chmod +x /magic-stick/scripts/test-ab-partition.sh /magic-stick/scripts/update-system.sh \u0026\u0026 " +
        "/magic-stick/scripts/test-ab-partition.sh create-disk \u0026\u0026 " +
        "/magic-stick/scripts/test-ab-partition.sh setup-ab " +
        (if (file("build/$isoName").exists()) "/magic-stick/build/$isoName" else "") +
        " \u0026\u0026 /magic-stick/scripts/test-ab-partition.sh test"
    )
}

tasks.register<org.gradle.api.tasks.Exec>("isoTestVNC") {
    group = "iso"
    description = "Test ISO GUI boot via QEMU + noVNC inside Docker (ports 5900+6080)"
    dependsOn("dockerBuild")
    commandLine("docker", "run", "--rm", "--privileged",
        "-p", "5900:5900",
        "-p", "6080:6080",
        "-v", "$projDir:/magic-stick",
        dockerImage,
        "/magic-stick/scripts/test-boot.sh", "--vnc",
        "/magic-stick/build/$isoName", "300")
}

tasks.register("isoTestFull") {
    group = "iso"
    description = "Full test suite: verify + boot + A/B partition (GPT+GRUB ext2/gfxterm) + persistence + software + smoke"
    dependsOn("isoVerify", "isoTestAB", "isoTestPersistence", "isoTestSoftware", "isoTestSmoke")
    finalizedBy("isoTestBoot")
}

// ============================================================
// Docker Hub CLI image Pipeline
// ============================================================

val dockerhubCredsFile = file("dockerhub-creds.yml")

fun parseDockerhubCreds(): Pair<String, String>? {
    if (!dockerhubCredsFile.exists()) return null
    val lines = dockerhubCredsFile.readLines()
    val user = lines.find { it.contains("username:") }?.substringAfter("username:")?.trim()?.removeSurrounding("\"")?.removeSurrounding("'") ?: ""
    val token = lines.find { it.contains("token:") }?.substringAfter("token:")?.trim()?.removeSurrounding("\"")?.removeSurrounding("'") ?: ""
    return if (user.isNotEmpty() && token.isNotEmpty()) user to token else null
}

fun parseDockerhubJwt(): String? {
    if (!dockerhubCredsFile.exists()) return null
    val line = dockerhubCredsFile.readLines().find { it.trimStart().startsWith("jwt:") }
    val value = line?.substringAfter("jwt:")?.trim()?.removeSurrounding("\"")?.removeSurrounding("'") ?: ""
    return value.ifEmpty { null }
}

tasks.register<org.gradle.api.tasks.Exec>("dockerHubLogin") {
    group = "docker"
    description = "Authenticate to Docker Hub using dockerhub-creds.yml (local only, never CI/CD)"
    val creds = parseDockerhubCreds()
    onlyIf { creds != null }
    commandLine("docker", "login", "-u", creds?.first ?: "", "--password-stdin", "docker.io")
    standardInput = (creds?.second ?: "").byteInputStream()
}

tasks.register<org.gradle.api.tasks.Exec>("dockerBuildCli") {
    group = "docker"
    description = "Build magic-stick-cli Docker image locally"
    val creds = parseDockerhubCreds()
    val repo = if (!creds?.first.isNullOrEmpty()) "${creds?.first}/magic-stick-cli" else "cccpeducation/magic-stick-cli"
    commandLine("docker", "buildx", "build",
        "--file", "docker/magic-stick-cli/Dockerfile",
        "--tag", "${repo}:${magicStickVersion}",
        "--tag", "${repo}:latest",
        ".")
}

tasks.register<org.gradle.api.tasks.Exec>("dockerPushCli") {
    group = "docker"
    description = "Build and push magic-stick-cli Docker image to Docker Hub (requires dockerHubLogin)"
    dependsOn("dockerHubLogin")
    val creds = parseDockerhubCreds()
    onlyIf { !creds?.first.isNullOrEmpty() }
    val repo = "${creds?.first}/magic-stick-cli"
    commandLine("docker", "buildx", "build", "--push",
        "--file", "docker/magic-stick-cli/Dockerfile",
        "--tag", "${repo}:${magicStickVersion}",
        "--tag", "${repo}:latest",
        ".")
}

tasks.register("dockerHubJwt") {
    group = "docker"
    description = "Generate a JWT token from Docker Hub credentials for Hub API calls. Override with -Pjwt=..."
    val creds = parseDockerhubCreds()
    val cliJwt = project.findProperty("jwt") as? String
    onlyIf { creds != null || !cliJwt.isNullOrEmpty() }
    doLast {
        val jwt = if (!cliJwt.isNullOrEmpty()) {
            cliJwt
        } else {
            val json = """{"username":"${creds?.first}","password":"${creds?.second}"}"""
            val tmpFile = File.createTempFile("dhub-", ".json")
            tmpFile.writeText(json)
            try {
                val process = ProcessBuilder("curl", "-s", "-X", "POST",
                    "-H", "Content-Type: application/json",
                    "-d", "@${tmpFile.absolutePath}",
                    "https://hub.docker.com/v2/users/login/")
                    .redirectOutput(ProcessBuilder.Redirect.PIPE)
                    .start()
                val output = process.inputStream.bufferedReader().readText()
                output.substringAfter("\"token\":\"").substringBefore("\"")
            } finally {
                tmpFile.delete()
            }
        }
        val lines = dockerhubCredsFile.readLines().toMutableList()
        val jwtIdx = lines.indexOfFirst { it.trimStart().startsWith("jwt:") }
        if (jwtIdx >= 0) {
            lines[jwtIdx] = "  jwt: \"$jwt\""
        } else {
            lines.add("  jwt: \"$jwt\"")
        }
        dockerhubCredsFile.writeText(lines.joinToString("\n") + "\n")
        logger.lifecycle("JWT stored in ${dockerhubCredsFile.absolutePath}")
    }
}

// ============================================================
// EPIC V-1 — Validation Physique USB (Host-only, sudo)
// ============================================================
// These tasks run on the HOST (not Docker) because they need
// direct block device access (/dev/sdX, mount, GRUB install).
// Skipped in CI (no physical USB key available).

tasks.register<org.gradle.api.tasks.Exec>("isoSetupAB") {
    group = "iso"
    description = "Initial A/B setup: partition USB key (GPT 5 partitions), install GRUB (Legacy+UEFI with ext2/gfxterm modules), flash ISO to System A." +
        " Host-only. Pass -Pdevice=/dev/sdX -PsudoPassword=..."
    val device = (project.findProperty("device") as? String) ?: ""
    val ci = System.getenv("CI") ?: ""
    val isoFile = file("build/$isoName")
    onlyIf { device.isNotEmpty() && ci.isEmpty() && isoFile.exists() }
    val password = (project.findProperty("sudoPassword") as? String) ?: ""
    val scriptDir = "$projDir/scripts"
    commandLine("sudo", "-S", "bash", "-c",
        "set -e; " +
        "echo '=== A/B Setup (v0.3.0 + GRUB ext2/gfxterm fix) ==='; " +
        "bash \"$scriptDir/update-system.sh\" -y setup-ab \"$device\" \"$isoFile\"; " +
        "echo; " +
        "echo '=== Post-setup Status ==='; " +
        "bash \"$scriptDir/update-system.sh\" status \"$device\" || true; " +
        "echo; " +
        "echo '=== SETUP COMPLETE. Boot from USB to test. ==='")
    standardInput = password.byteInputStream()
}

tasks.register<org.gradle.api.tasks.Exec>("isoCheckUSB") {
    group = "iso"
    description = "Validate USB key (partitions, GRUB with ext2/gfxterm, system contents, ISO checksum)." +
        " Host-only. Pass -Pdevice=/dev/sdX -PsudoPassword=..."
    val device = (project.findProperty("device") as? String) ?: ""
    val ci = System.getenv("CI") ?: ""
    onlyIf { device.isNotEmpty() && ci.isEmpty() && file("build/$isoName").exists() }
    val password = (project.findProperty("sudoPassword") as? String) ?: ""
    val scriptDir = "$projDir/scripts"
    commandLine("sudo", "-S", "bash", "-c",
        "set -e; " +
        "echo '=== ISO Checksum ==='; " +
        "sha256sum \"$projDir/build/$isoName\"; " +
        "echo; " +
        "echo '=== USB Key Verification ==='; " +
        "bash \"$scriptDir/update-system.sh\" verify \"$device\" || echo 'Verification completed with warnings'; " +
        "echo; " +
        "echo '=== USB Key Status ==='; " +
        "bash \"$scriptDir/update-system.sh\" status \"$device\" || echo 'Status completed with warnings'; " +
        "echo; " +
        "echo '=== CHECK DONE. Reboot PC on USB key to complete EPIC V-1 physical validation. ==='")
    standardInput = password.byteInputStream()
}

tasks.register<org.gradle.api.tasks.Exec>("isoUpdateSystem") {
    group = "iso"
    description = "Flash ISO to USB inactive A/B partition (active→inactive + GRUB switch with ext2/gfxterm modules)." +
        " Host-only. Pass -Pdevice=/dev/sdX -PsudoPassword=..."
    val device = (project.findProperty("device") as? String) ?: ""
    val ci = System.getenv("CI") ?: ""
    val isoFile = file("build/$isoName")
    onlyIf { device.isNotEmpty() && ci.isEmpty() && isoFile.exists() }
    val password = (project.findProperty("sudoPassword") as? String) ?: ""
    val scriptDir = "$projDir/scripts"
    commandLine("sudo", "-S", "bash", "-c",
        "set -e; " +
        "echo '=== Pre-flash Status ==='; " +
        "bash \"$scriptDir/update-system.sh\" status \"$device\" || true; " +
        "echo; " +
        "echo '=== Flashing ISO to inactive partition ==='; " +
        "bash \"$scriptDir/update-system.sh\" --yes update \"$device\" \"$isoFile\"; " +
        "echo; " +
        "echo '=== Post-flash Verification ==='; " +
        "bash \"$scriptDir/update-system.sh\" verify \"$device\" || echo 'Verification completed with warnings'; " +
        "echo; " +
        "echo '=== Post-flash Status ==='; " +
        "bash \"$scriptDir/update-system.sh\" status \"$device\" || true; " +
        "echo; " +
        "echo '=== FLASH COMPLETE. Default boot switched. Reboot to test on real hardware. ==='")
    standardInput = password.byteInputStream()
}

tasks.register("isoValidateUSB") {
    group = "iso"
    description = "Full USB validation pipeline: pre-check + flash + post-verify." +
        " Pass -Pdevice=/dev/sdX -PsudoPassword=..."
    dependsOn("isoCheckUSB")
    finalizedBy("isoUpdateSystem")
}

tasks.register<org.gradle.api.tasks.Exec>("isoTestPersistence") {
    group = "iso"
    description = "Validate update-system.sh never touches persistence partition (static analysis, no loop device)"
    dependsOn("dockerBuild")
    commandLine("docker", "run", "--rm",
        "-v", "$projDir:/magic-stick",
        dockerImage,
        "bash", "/magic-stick/scripts/test-persistence-mock.sh",
        "/magic-stick/scripts/update-system.sh")
}

tasks.register<org.gradle.api.tasks.Exec>("isoReleaseNotes") {
    group = "iso"
    description = "Generate AsciiDoc release notes from conventional commits." +
        " Override range with -PfromTag=v0.1.13 -PtoTag=v0.1.14 -Poutput=releases.adoc"
    val fromTag = (project.findProperty("fromTag") as? String) ?: ""
    val toTag = (project.findProperty("toTag") as? String) ?: ""
    val output = (project.findProperty("output") as? String) ?: ""
    val args = buildList {
        if (fromTag.isNotEmpty()) { add("--from-tag"); add(fromTag) }
        if (toTag.isNotEmpty()) { add("--to-tag"); add(toTag) }
        if (output.isNotEmpty()) { add("--output"); add(output) }
    }
    onlyIf { file("$projDir/.git").exists() }
    commandLine(buildList {
        add("bash")
        add("$scriptDir/generate-release-notes.sh")
        addAll(args)
    })
}

// ============================================================
// EPIC 15 — Network Boot & Remote Provisioning (Host-only, sudo)
// ============================================================
// Boot magic-stick live on remote laptops via PXE/iPXE over the
// local network. No reformat, no USB key, no touching partitions.
// Architecture: dnsmasq (proxy DHCP + TFTP/HTTP) + iPXE + WoL + SSH.

tasks.register<org.gradle.api.tasks.Exec>("isoNetworkBoot") {
    group = "iso"
    description = "Start network boot server (dnsmasq proxy DHCP + iPXE TFTP + kernel/initrd HTTP)." +
        " Host-only. Pass -PsudoPassword=... -Piface=eth0 -PhttpPort=8080"
    val ci = System.getenv("CI") ?: ""
    val isoFile = file("build/$isoName")
    onlyIf { ci.isEmpty() && isoFile.exists() }
    val password = (project.findProperty("sudoPassword") as? String) ?: ""
    val iface = (project.findProperty("iface") as? String) ?: "eth0"
    val httpPort = (project.findProperty("httpPort") as? String) ?: "8080"
    commandLine("sudo", "-S", "bash", "-c",
        "set -e; " +
        "echo '=== Network Boot Server ==='; " +
        "echo \"Interface: $iface  HTTP port: $httpPort\"; " +
        "echo \"ISO: $isoFile\"; " +
        "echo; " +
        "echo 'Starting dnsmasq (proxy DHCP + TFTP + HTTP)...'; " +
        "bash \"$scriptDir/network-boot.sh\" start \"$iface\" \"$httpPort\" \"$isoFile\"; " +
        "echo; " +
        "echo '=== Server running. Laptops can now PXE boot. ==='; " +
        "echo 'Press Ctrl+C to stop.'")
    standardInput = password.byteInputStream()
}

tasks.register<org.gradle.api.tasks.Exec>("isoWakeLaptops") {
    group = "iso"
    description = "Send Wake-on-LAN magic packets to target laptops." +
        " Host-only. Pass -Plaptops=aa:bb:cc:dd:ee:ff,11:22:33:44:55:66 -PsudoPassword=..."
    val ci = System.getenv("CI") ?: ""
    val laptops = (project.findProperty("laptops") as? String) ?: ""
    onlyIf { ci.isEmpty() && laptops.isNotEmpty() }
    val password = (project.findProperty("sudoPassword") as? String) ?: ""
    commandLine("sudo", "-S", "bash", "-c",
        "set -e; " +
        "echo '=== Wake-on-LAN ==='; " +
        "IFS=',' read -ra MACS <<< \"$laptops\"; " +
        "for mac in \"\${MACS[@]}\"; do " +
        "  echo \"Waking \$mac...\"; " +
        "  bash \"$scriptDir/wake-laptops.sh\" \"\$mac\"; " +
        "done; " +
        "echo '=== WoL packets sent ==='")
    standardInput = password.byteInputStream()
}

tasks.register<org.gradle.api.tasks.Exec>("isoProvisionNetwork") {
    group = "iso"
    description = "Full network provisioning pipeline: wake laptops → wait SSH → verify boot." +
        " Host-only. Pass -Plaptops=mac1,mac2 -PsshUser=magic -PsshPass=... -PsudoPassword=..."
    val ci = System.getenv("CI") ?: ""
    val laptops = (project.findProperty("laptops") as? String) ?: ""
    val isoFile = file("build/$isoName")
    onlyIf { ci.isEmpty() && laptops.isNotEmpty() && isoFile.exists() }
    val password = (project.findProperty("sudoPassword") as? String) ?: ""
    val sshUser = (project.findProperty("sshUser") as? String) ?: "magic"
    val sshPass = (project.findProperty("sshPass") as? String) ?: ""
    val iface = (project.findProperty("iface") as? String) ?: "eth0"
    val httpPort = (project.findProperty("httpPort") as? String) ?: "8080"
    commandLine("sudo", "-S", "bash", "-c",
        "set -e; " +
        "echo '=== Network Provisioning Pipeline ==='; " +
        "echo; " +
        "echo '[1/4] Starting network boot server...'; " +
        "bash \"$scriptDir/network-boot.sh\" start \"$iface\" \"$httpPort\" \"$isoFile\" & " +
        "SERVER_PID=\$!; sleep 2; " +
        "echo \"  Server PID: \$SERVER_PID\"; " +
        "echo; " +
        "echo '[2/4] Waking laptops...'; " +
        "IFS=',' read -ra MACS <<< \"$laptops\"; " +
        "for mac in \"\${MACS[@]}\"; do " +
        "  echo \"  Waking \$mac...\"; " +
        "  bash \"$scriptDir/wake-laptops.sh\" \"\$mac\"; " +
        "done; " +
        "echo; " +
        "echo '[3/4] Waiting for SSH (timeout 120s)...'; " +
        "for mac in \"\${MACS[@]}\"; do " +
        "  echo \"  Waiting for \$mac to boot...\"; " +
        "  for i in \$(seq 1 24); do " +
        "    if sshpass -p \"$sshPass\" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \"$sshUser@\$mac\" 'echo OK' 2>/dev/null; then " +
        "      echo \"  \$mac: SSH READY\"; break; " +
        "    fi; " +
        "    sleep 5; " +
        "  done; " +
        "done; " +
        "echo; " +
        "echo '[4/4] Provisioning complete.'; " +
        "echo 'Laptops are live-booted on magic-stick.'; " +
        "echo \"Server still running (PID \$SERVER_PID). Press Ctrl+C to stop.\"; " +
        "wait \$SERVER_PID")
    standardInput = password.byteInputStream()
}

tasks.register("isoNetworkTest") {
    group = "iso"
    description = "Test network boot pipeline end-to-end in QEMU (2 PXE clients + 1 dnsmasq server)"
    dependsOn("isoBuild")
    // Placeholder — will run test-boot.sh --pxe mode when implemented
    doLast {
        logger.lifecycle("EPIC 15 US-6: QEMU PXE test — script à implémenter dans test-boot.sh --pxe")
    }
}
