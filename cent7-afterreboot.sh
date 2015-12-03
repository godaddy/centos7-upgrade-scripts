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
# PHASE 2
#

# This stuff runs once the box has been rebooted into Cent 7 after the upgrade

export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/opt/dell/srvadmin/bin:/opt/dell/srvadmin/sbin:/root/bin

DATESTART=`date`

# Remove all the extra stuff from rc.local that we put in there with cent7-upgrade.sh
head -n -15 /etc/rc.d/rc.local > /tmp/rc.local
mv -f /tmp/rc.local /etc/rc.d/rc.local
chmod 755 /etc/rc.d/rc.local

# Fix up the /usr/bin/python symlink, it'll still point to python2.6 at this point
rm -f /usr/bin/python
ln -s /usr/bin/python2.7 /usr/bin/python

# Configure the yum repo for the v7 Spacewalk stuff
cat >/etc/yum.repos.d/spacewalk-v7.repo <<EOF
[spacewalk-v7]
name=spacewalk-v7
enabled=1
baseurl=http://spacewalk_api_host/ks/dist/child/gd-spacewalk-client-dev-v7-64bit/gd-centos-development-base-v7-64bit
EOF

# Upgrade all the Spacewalk packages, retry until we get it done
yumres=1
while [ $yumres -ne 0 ] ; do
  yum update spacewalk\* rhn\* osad\* -y
  yumres=$?
done

yumres=1
while [ $yumres -ne 0 ] ; do
  yum update -y yum-rhn-plugin
  yumres=$?
done

# rc.local stuff should have done this, but just in case make sure we've got the
# symlink for the old libpcre
# (otherwise the 'grep' command doesn't work)
[ ! -e libpcre.so.0 ] && ln -s libpcre.so.1.2.0 libpcre.so.0

# pyOpenSSL is a special one.  None of the above stuff properly upgrades it, so
# we have to explicity remove and reinstall
rpm -e pyOpenSSL --nodeps

yumres=1
while [ $yumres -ne 0 ] ; do
  yum --enablerepo redhat-upgrade-cmdline-instrepo install -y pyOpenSSL
  yumres=$?
done

echo -n 'Started:  '
echo $DATESTART
echo -n 'Finished: '
date
