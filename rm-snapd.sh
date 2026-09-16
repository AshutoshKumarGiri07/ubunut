systemctl stop snapd.service snapd.socket

snap list

snap list | awk 'NR>1 {print $1}' | xargs -r snap remove --purge

systemctl disable snapd.service snapd.socket

apt purge -y snapd

rm -rf /snap
rm -rf /var/snap
rm -rf /var/lib/snapd
rm -rf /var/cache/snapd
rm -rf ~/snap
rm -rf /root/snap

apt autoremove -y --purge
apt autoclean
