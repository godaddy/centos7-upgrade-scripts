#!/bin/bash -x
#
# Copyright 2015 Go Daddy
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

#
# PHASE 1
#

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/opt/dell/srvadmin/bin:/opt/dell/srvadmin/sbin:/root/bin

DATESTART=`date`

# Start fresh
yum clean all

# Don't care if this fails here, the playbook will verify it's installed later
yum install -y biosdevname

# Add the upgrade repo
cat >/etc/yum.repos.d/upg.repo <<EOF
[upg]
name=CentOS-\$releasever - Upgrade Tool
baseurl=http://dev.centos.org/centos/6/upg/x86_64/
gpgcheck=1
enabled=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-6
EOF

# Install upgrade tools (loop until it's successful)
yumres=1
while [ $yumres -ne 0 ] ; do
  yum -y install redhat-upgrade-tool preupgrade-assistant-contents
  yumres=$?
done

# Run the preupgrade steps and save output
echo "y" | preupg -s CentOS6_7 1>>/root/preupg-output.txt 2>&1 || exit 1

# Import the repo's GPG key
rpm --import http://mirror.centos.org/centos/RPM-GPG-KEY-CentOS-7 || exit 1

# Selinux must be turned off-ish for this all to work
semodule -r sandbox

# Make sure the SCL repo is disabled
sed -i -r 's/enabled=.+/enabled=0/' /etc/yum.repos.d/CentOS-SCL.repo

# Start fresh, again!
yum clean all

# Clear out any extra kernels
rpm -q kernel | grep -v `uname -r` | xargs rpm -e

# Remove SCL's (don't worry, after we upgrade to Cent 7, we'll have the needed
# Ruby and Python stuff)
# (Note: neutron-openvswitch-agent will start logging tons of errors after this
# point.  That's ok, but messy.  So we stop the ovs agent here before, since
# after python27 is removed, it can't do anything anyway)
service openstack-neutron-openvswitch-agent stop
yum -y remove ruby193\*
yum -y remove python27\*

# Fix upgrade tool code (this is getting very hacky)
# Not 100% sure what's going on here, but without this the tool fails on trying
# to resolve all the dependencies.
cwd=${PWD}
cd /usr/lib/python2.6/site-packages/redhat_upgrade_tool/
patch <<EOF
--- /usr/lib/python2.6/site-packages/redhat_upgrade_tool/download.py	2014-07-28 10:40:14.000000000 -0700
+++ /usr/lib/python2.6/site-packages/redhat_upgrade_tool/download.py	2015-11-20 11:19:26.889264030 -0700
@@ -263,6 +263,8 @@
         problems = []

         def find_replacement(po):
+            if po == None:
+                return None, po
             for tx in self.tsInfo.getMembers(po.pkgtup):
                 # XXX multiple replacers?
                 for otherpo, rel in tx.relatedto:
EOF
cd ${cwd}

# Try running the upgrade tool up to 5 times.  (Most failures are due to
# yum/spacewalk timeouts/errors, so we just try again)
for i in {1..5} ; do
  echo centos-upgrade-tool-cli attempt $i
  centos-upgrade-tool-cli -v -d --network 7 --instrepo=http://spacewalk_api_host/ks/dist/gd-centos-production-base-v7-64bit --force 1>>/root/upgrade-tool-output.txt 2>&1
  upgres=$?
  # Break out of the loop if we succeeded
  [ $upgres -eq 0 ] && break
done

# Exit with error if the upgrade tool failed
[ $upgres -ne 0 ] && exit 1

# Stick stuff into rc.local that we need to happen right at bootup after the upgrade
# - Maintain old sasl2 and pcre libraries that are still needed temporarily
# - Retool the network config for the new bios names under systemd
cat >>/etc/rc.d/rc.local <<EOF
cd /lib64
[ ! -e libsasl2.so.2 ] && ln -s libsasl2.so.3 libsasl2.so.2
[ ! -e libpcre.so.0 ] && ln -s libpcre.so.1.2.0 libpcre.so.0
rm -f /usr/bin/python
ln -s /usr/bin/python2.7 /usr/bin/python
sleep 60
/sbin/ifconfig em1 up ; /sbin/ifconfig em2 up ; /sbin/ifconfig em3 up ; /sbin/ifconfig em4 up
sed -i 's/eth0/em1/g' /etc/sysconfig/network-scripts/ifcfg-bond0
sed -i 's/eth2/em3/g' /etc/sysconfig/network-scripts/ifcfg-bond0
sed -i 's/eth0/em1/g' /etc/sysconfig/network-scripts/ifcfg-eth0 ; mv /etc/sysconfig/network-scripts/ifcfg-eth0 /etc/sysconfig/network-scripts/ifcfg-em1
sed -i 's/eth1/em2/g' /etc/sysconfig/network-scripts/ifcfg-eth1 ; mv /etc/sysconfig/network-scripts/ifcfg-eth1 /etc/sysconfig/network-scripts/ifcfg-em2
sed -i 's/eth2/em3/g' /etc/sysconfig/network-scripts/ifcfg-eth2 ; mv /etc/sysconfig/network-scripts/ifcfg-eth2 /etc/sysconfig/network-scripts/ifcfg-em3
sed -i 's/eth3/em4/g' /etc/sysconfig/network-scripts/ifcfg-eth3 ; mv /etc/sysconfig/network-scripts/ifcfg-eth3 /etc/sysconfig/network-scripts/ifcfg-em4
ovs-vsctl del-port bond0
systemctl restart network
EOF

# The upgrade tool doesn't properly populate the initrd option in grub.conf
# I've also seen it where it doesn't configure a section for the new kernel at all
# So instead we use this postupgrade.d script to lay down a known-good grub.conf
# (This runs after the upgrade work has been done, but before the reboot.)
cat >/root/preupgrade/postupgrade.d/zz_grub_fixup.sh <<EOF
#!/bin/bash
cat >/boot/grub/grub.conf <<EOG
# grub.conf generated by anaconda
#
# Note that you do not have to rerun grub after making changes to this file
# NOTICE:  You have a /boot partition.  This means that
#          all kernel and initrd paths are relative to /boot/, eg.
#          root (hd0,0)
#          kernel /vmlinuz-version ro root=/dev/mapper/VolGroup00-root
#          initrd /initrd-[generic-]version.img
#boot=/dev/sda
default=2
timeout=5
splashimage=(hd0,0)/grub/splash.xpm.gz
hiddenmenu
title System Upgrade (redhat-upgrade-tool)
  root (hd0,0)
  kernel /vmlinuz-redhat-upgrade-tool ro root=/dev/mapper/VolGroup00-root rd_NO_LUKS LANG=en_US.UTF-8 rd_NO_MD rd_LVM_LV=VolGroup00/swap SYSFONT=latarcyrheb-sun16 crashkernel=auto rd_LVM_LV=VolGroup00/root  KEYBOARDTYPE=pc KEYTABLE=us rd_NO_DM upgrade init=/usr/libexec/upgrade-init selinux=0 rd.plymouth=0 plymouth.enable=0 net.ifnames=0 consoleblank=0
  initrd /initramfs-redhat-upgrade-tool.img
title CentOS (2.6.32-504.16.2.el6.x86_64)
  root (hd0,0)
  kernel /vmlinuz-2.6.32-504.16.2.el6.x86_64 ro root=/dev/mapper/VolGroup00-root rd_NO_LUKS LANG=en_US.UTF-8 rd_NO_MD rd_LVM_LV=VolGroup00/swap SYSFONT=latarcyrheb-sun16 crashkernel=auto rd_LVM_LV=VolGroup00/root  KEYBOARDTYPE=pc KEYTABLE=us rd_NO_DM rhgb quiet
  initrd /initramfs-2.6.32-504.16.2.el6.x86_64.img
title CentOS (3.10)
  root (hd0,0)
  kernel /vmlinuz-3.10.0-229.el7.x86_64 ro root=/dev/mapper/VolGroup00-root rd_NO_LUKS LANG=en_US.UTF-8 rd_NO_MD rd_LVM_LV=VolGroup00/swap SYSFONT=latarcyrheb-sun16 crashkernel=auto rd_LVM_LV=VolGroup00/root  KEYBOARDTYPE=pc KEYTABLE=us rd_NO_DM rhgb quiet
  initrd /initramfs-3.10.0-229.el7.x86_64.img
EOG
EOF
chmod +x /root/preupgrade/postupgrade.d/zz_grub_fixup.sh

# Do some sanity checking to make sure the upgrade tool set the default grub
# entry to the upgrade kernel
grubby --default-kernel | grep upgrade || exit 1

# Stop nova compute (we can't use service command because the nova-compute
# package has been uninstalled at this point)
killall nova-compute
sleep 5

echo -n "Started:  "
echo $DATESTART
echo -n "Finished: "
date
