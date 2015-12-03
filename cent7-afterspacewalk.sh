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
# PHASE 3
#

# This runs after the box has booted after the upgrade AND moved to the new v7
# base channel in Spacewalk

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/opt/dell/srvadmin/bin:/opt/dell/srvadmin/sbin:/root/bin

DATESTART=`date`

# Generic retry function that handles retrying commands until it succeeds
function retry_until_success {
  res=1
  while [ $res -ne 0 ] ; do
    $@
    res=$?
    [ $res -ne 0 ] && sleep 2
  done
}

# Wait for new base channel to be effective
while [ `rhn-channel --list | grep base` != 'gd-centos-production-base-v7-64bit' ]; do echo Waiting for Spacewalk base channel update... ; sleep 5 ; done

# Add all the child channels (repos) we need
# (Go Daddy-specific commands removed)

# Disable previous directly configured yum repos
sed -i -r 's/enabled=.+/enabled=0/' /etc/yum.repos.d/upg.repo
sed -i -r 's/enabled=.+/enabled=0/' /etc/yum.repos.d/spacewalk-v7.repo

# And proceed to fix up any packages that aren't completely upgraded properly
rpm -e perl-5.10.1-119.el6 --nodeps
retry_until_success yum -y update perl\*

rpm -e python-2.6.6-29.el6 --nodeps
rpm -e python-flask --nodeps
retry_until_success yum install python-flask -y

rpm -q openldap && rpm -e --justdb openldap --nodeps && retry_until_success yum -y install openldap

rpm -q ruby-libs | grep el6 | xargs yum -y remove
retry_until_success yum -y install puppet

retry_until_success yum remove centos-release-SCL -y

# These shouldn't be needed if /boot is larger than 100M
BOOTSIZE=`df /boot | grep /boot | awk '{print $2;}'`
if [ $BOOTSIZE -lt 100000 ]; then
  rpm -q kernel | grep kernel-2 | xargs rpm -e
  mv -f /boot/initramfs-redhat-upgrade-tool.img /boot/vmlinuz-redhat-upgrade-tool /root/
fi

retry_until_success yum -y remove source-highlight audit

rpm -e mesa-dri-drivers-10.4.3-1.el6.x86_64 --nodeps
rpm -e libdrm-2.4.59-2.el6.x86_64 --nodeps
retry_until_success yum install -y libdrm mesa-dri-drivers
rpm -qa | grep el6 | grep python | xargs yum remove -y
retry_until_success yum install -y yum-plugin-changelog yum-utils
retry_until_success yum remove -y PyYAML-3.11-0.el6.x86_64
rpm -e python-requests --nodeps
retry_until_success yum install -y python-requests-2.5.1-0.el7.centos.noarch  --disableexcludes=all
rpm -e glusterfs-api glusterfs glusterfs-libs --nodeps
retry_until_success yum install -y glusterfs-api glusterfs glusterfs-libs

retry_until_success yum -y update

retry_until_success yum reinstall python -y

rpm -e python-oslo-config --nodeps
retry_until_success yum -y reinstall python-oslo\*

# Make sure needed services are enabled
systemctl enable snmpd.service
systemctl enable ntpd.service
systemctl enable rsyslog.service
systemctl enable logstash.service

retry_until_success yum install -y rubygem-r10k rubygem-hiera-eyaml

rpm -q netcf-libs && rpm -e netcf-libs --nodeps && retry_until_success yum -y install netcf-libs
rpm -q libnl3 && rpm -e libnl3 --nodeps && retry_until_success yum -y install libnl3
rpm -q audit-libs && rpm -e audit-libs --nodeps && retry_until_success yum -y install audit-libs

rpm -e elfutils-libelf --justdb --nodeps
retry_until_success yum -y install elfutils-libelf

rpm -e elfutils --justdb --nodeps
rpm -e elfutils-libs --justdb --nodeps
retry_until_success yum -y install elfutils elfutils-libs

rpm -e libX11 --nodeps ; rpm -e libX11-common --nodeps
retry_until_success yum -y install libX11 libX11-common
retry_until_success yum -y install libXi

rpm -q spice-server && rpm -e spice-server --nodeps && retry_until_success yum -y install spice-server
rpm -e cairo --nodeps && retry_until_success yum -y install cairo mesa-libGL mesa-libEGL
retry_until_success yum -y remove cloog-ppl gd-ruby-shadow hal-info ppl readahead crmsh gd-ruby perl-Config-General
rpm -q diamond && rpm -e diamond && retry_until_success yum -y install diamond

# Try to remove and reinstall any remaining el6 packages that are still present
# (Ignoring those that are expected and/or we want to keep the el6 version)
YUMINSTALL=
for i in `rpm -qa | grep el6 | grep -v logstash | grep -v gd-pbis-utils | grep -v srvadmin | grep -v smbios | grep -v statsd | grep -v nss | grep -v kernel | grep -v elf`; do
  NAME=`rpm -q --qf "%{NAME}" $i`
  rpm -e $NAME --nodeps
  YUMINSTALL="$YUMINSTALL $NAME"
done
retry_until_success yum -y install $YUMINSTALL

retry_until_success yum -y install libyaml tzdata gtk2 spice-server compute-serverspec-tests

# Check dependencies, there should be no deps errors, other than maybe one for
# pbis-entprise (which we can ignore)
echo =======================================================================
yum check dependencies
echo =======================================================================

# Install grub2 bootloader
# First create a bios_grub GPT partition at the beginning of the disk
parted -s /dev/sda print free
parted -s /dev/sda mkpart primary 17.5kB 1048kB
parted -s /dev/sda print
parted -s /dev/sda set 3 bios_grub on
parted -s /dev/sda print

# Remove any uneeded kernels, including the special upgrade tool kernel
# And generate a proper grub2 config
rpm -q kernel | grep -v `uname -r` | xargs rpm -e
cd /boot
rm -f initramfs-redhat-upgrade-tool.img vmlinuz-redhat-upgrade-tool
mv grub x.grub
rm -f /etc/grub.conf
grub2-mkconfig -o /boot/grub2/grub.cfg
ln -s /boot/grub2/grub.cfg /etc/grub.cfg
grub2-install /dev/sda

# Make sure we're on the latest kernel and sanity check grub2 is installed
yum -y update kernel

grubby --default-kernel
file -s /dev/sda

echo -n 'Started:  '
echo $DATESTART
echo -n 'Finished: '
date
