#!/usr/bin/env bash
set -euo pipefail

# magic-stick-welcome.sh — Fenetre de bienvenue au premier demarrage XFCE

VERSION_FILE="/etc/magic-stick/version"
VERSION="inconnue"
if [[ -r "$VERSION_FILE" ]]; then
    VERSION="$(head -n 1 "$VERSION_FILE" | tr -d '[:space:]')"
fi

title="Bienvenue sur Magic Stick ${VERSION}"

zenity --info \
    --title="$title" \
    --width=480 \
    --icon-name=magic-stick \
    --text="<b>Magic Stick ${VERSION}</b>\n\n"
        "Environnement de developpement portable.\n"
        "Tous les outils sont prets — terminal, IDE, containers, reseau.\n\n"
        "Raccourcis:\n"
        "<b>Super + T</b>  Terminal\n"
        "<b>Super + F</b>  Fichiers\n"
        "<b>Super + B</b>  Firefox\n"
        "<b>Super + 1..4</b>  Bureaux\n\n"
        "Documentation: <a href='https://cccp-education.github.io/magic-stick/'>https://cccp-education.github.io/magic-stick/</a>" || true
