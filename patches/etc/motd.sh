#!/data/data/com.klyx/files/usr/bin/bash
source "/data/data/com.klyx/files/usr/bin/termux-setup-package-manager" || exit 1

terminal_width="$(stty size | cut -d" " -f2)"
if [[ "$terminal_width" =~ ^[0-9]+$ ]] && [ "$terminal_width" -gt 60 ]; then
    motd="
 \e[1mWelcome to Klyx Terminal!\e[0m

 \e[1mWorking with packages:\e[0m
 \e[1mSearch:\e[0m  pkg search <query>
 \e[1mInstall:\e[0m pkg install <package>
 \e[1mUpgrade:\e[0m pkg upgrade
"
else
    motd="
\e[1mWelcome to Klyx Terminal!\e[0m
\e[1mSearch:\e[0m  pkg search <query>
\e[1mInstall:\e[0m pkg install <package>
\e[1mUpgrade:\e[0m pkg upgrade
"
fi

echo -e "$motd"
