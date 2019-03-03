#!/usr/bin/env bash
# This scripts runs as root

setupVars="/etc/pi-guard/setupVars.conf"

if [ ! -f "${setupVars}" ]; then
    echo "::: Missing setup vars file!"
    exit 1
fi

source "${setupVars}"

EXAMPLE="$(head -1 /etc/wireguard/configs/clients.txt | awk '{print $1}')"
ERR=0

echo -e "::::\t\t\e[4mPi-guard debug\e[0m\t\t ::::"
printf "=============================================\n"
echo -e "::::\t    \e[4mInstallation settings\e[0m    \t ::::"
sed "s/$PUBLICDNS/PUBLICDNS/" <  /etc/pi-guard/setupVars.conf
printf "=============================================\n"
echo -e "::::  \e[4mServer configuration shown below\e[0m   ::::"
cd /etc/wireguard/keys
cp ../wg0.conf ../wg0.tmp
for k in *; do
    sed "s#$(cat "$k")#$k#" -i ../wg0.tmp
done
cat ../wg0.tmp
rm ../wg0.tmp
printf "=============================================\n"
echo -e "::::  \e[4mClient configuration shown below\e[0m   ::::"
cp ../configs/"$EXAMPLE".conf ../configs/"$EXAMPLE".tmp
for k in *; do
    sed "s#$(cat "$k")#$k#" -i ../configs/"$EXAMPLE".tmp
done
sed "s/$PUBLICDNS/PUBLICDNS/" < ../configs/"$EXAMPLE".tmp
rm ../configs/"$EXAMPLE".tmp
printf "=============================================\n"
echo -e ":::: \t\e[4mRecursive list of files in\e[0m\t ::::\n::::\e\t[4m/etc/wireguard shown below\e[0m\t ::::"
ls -LR /etc/wireguard
printf "=============================================\n"
echo -e "::::\t\t\e[4mSelf check\e[0m\t\t ::::"

if [ "$(cat /proc/sys/net/ipv4/ip_forward)" -eq 1 ]; then
    echo ":: [OK] IP forwarding is enabled"
else
    ERR=1
    read -r -p ":: [ERR] IP forwarding is not enabled, attempt fix now? [Y/n] " REPLY
    if [[ ${REPLY} =~ ^[Yy]$ ]]; then
        sed -i '/net.ipv4.ip_forward=1/s/^#//g' /etc/sysctl.conf
        sysctl -p
        echo "Done"
    fi
fi

if [ "$USE_UFW" = "False" ]; then

    if iptables -t nat -C POSTROUTING -s 10.6.0.0/24 -o "${piguardInterface}" -j MASQUERADE &> /dev/null; then
        echo ":: [OK] Iptables MASQUERADE rule set"
    else
        ERR=1
        read -r -p ":: [ERR] Iptables MASQUERADE rule is not set, attempt fix now? [Y/n] " REPLY
        if [[ ${REPLY} =~ ^[Yy]$ ]]; then
            iptables -t nat -F
            iptables -t nat -I POSTROUTING -s 10.6.0.0/24 -o "${piguardInterface}" -j MASQUERADE
            iptables-save > /etc/iptables/rules.v4
            iptables-restore < /etc/iptables/rules.v4
            echo "Done"
        fi
    fi

else

    if LANG="en_US.UTF-8" ufw status | grep -qw 'active'; then
        echo ":: [OK] Ufw is enabled"
    else
        ERR=1
        read -r -p ":: [ERR] Ufw is not enabled, try to enable now? [Y/n] " REPLY
        if [[ ${REPLY} =~ ^[Yy]$ ]]; then
            ufw enable
        fi
    fi

    if iptables -t nat -C POSTROUTING -s 10.6.0.0/24 -o "${piguardInterface}" -j MASQUERADE &> /dev/null; then
        echo ":: [OK] Iptables MASQUERADE rule set"
    else
        ERR=1
        read -r -p ":: [ERR] Iptables MASQUERADE rule is not set, attempt fix now? [Y/n] " REPLY
        if [[ ${REPLY} =~ ^[Yy]$ ]]; then
            sed "/delete these required/i *nat\n:POSTROUTING ACCEPT [0:0]\n-I POSTROUTING -s 10.6.0.0/24 -o $piguardInterface -j MASQUERADE\nCOMMIT\n" -i /etc/ufw/before.rules
            ufw reload
            echo "Done"
        fi
    fi

    if iptables -C ufw-user-input -p udp --dport "${PORT}" -j ACCEPT &> /dev/null; then
        echo ":: [OK] Ufw input rule set"
    else
        ERR=1
        read -r -p ":: [ERR] Ufw input rule is not set, attempt fix now? [Y/n] " REPLY
        if [[ ${REPLY} =~ ^[Yy]$ ]]; then
            ufw insert 1 allow "$PORT"/udp
            ufw reload
            echo "Done"
        fi
    fi

    if iptables -C ufw-user-forward -i wg0 -o "${piguardInterface}" -s 10.6.0.0/24 -j ACCEPT &> /dev/null; then
        echo ":: [OK] Ufw forwarding rule set"
    else
        ERR=1
        read -r -p ":: [ERR] Ufw forwarding rule is not set, attempt fix now? [Y/n] " REPLY
        if [[ ${REPLY} =~ ^[Yy]$ ]]; then
            ufw route insert 1 allow in on wg0 from 10.6.0.0/24 out on "$piguardInterface" to any
            ufw reload
            echo "Done"
        fi
    fi

fi

if systemctl is-active -q wg-quick@wg0; then
    echo ":: [OK] WireGuard is running"
else
    ERR=1
    read -r -p ":: [ERR] WireGuard is not running, try to start now? [Y/n] " REPLY
    if [[ ${REPLY} =~ ^[Yy]$ ]]; then
        systemctl start wg-quick@wg0
        echo "Done"
    fi
fi

if systemctl is-enabled -q wg-quick@wg0; then
    echo ":: [OK] WireGuard is enabled (it will automatically start on reboot)"
else
    ERR=1
    read -r -p ":: [ERR] WireGuard is not enabled, try to enable now? [Y/n] " REPLY
    if [[ ${REPLY} =~ ^[Yy]$ ]]; then
        systemctl enable wg-quick@wg0
        echo "Done"
    fi
fi

# grep -w (whole word) is used so port 111940 with now match when looking for 1194
if netstat -uanp | grep -w "${PORT}" | grep -q 'udp'; then
    echo ":: [OK] WireGuard is listening on port ${PORT}/udp"
else
    ERR=1
    read -r -p ":: [ERR] WireGuard is not listening, try to restart now? [Y/n] " REPLY
    if [[ ${REPLY} =~ ^[Yy]$ ]]; then
        systemctl restart wg-quick@wg0
        echo "Done"
    fi
fi

if [ "$ERR" -eq 1 ]; then
    echo -e "[INFO] Run \e[1mpi-guard -d\e[0m again to see if we detect issues"
fi
printf "=============================================\n"
echo -e ":::: \e[1mWARNING\e[0m: This script should have automatically masked sensitive       ::::"
echo -e ":::: information, however, still make sure that \e[4mPrivateKey\e[0m, \e[4mPublicKey\e[0m      ::::"
echo -e ":::: and \e[4mPresharedKey\e[0m are masked before reporting an issue. An example key ::::"
echo ":::: that you should NOT see in this log looks like this:                  ::::"
echo ":::: WJhKKx+Uk1l1TxaH2KcEGeBdPBTp/k/Qy4EpBig5UnI=                          ::::"
printf "=============================================\n"
echo -e "::::\t\t\e[4mDebug complete\e[0m\t\t ::::"
