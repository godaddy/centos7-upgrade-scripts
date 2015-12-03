# centos7-upgrade-scripts
Ansible playbook and supporting scripts for upgrading OpenStack compute/hypervisor hosts from CentOS 6 to 7

**NOTE: You almost certainly cannot drop this directly into your environment and have it work right!!**  This is what we used for our configuration and it is very specific to our setup and particular versions of packages and the kernel.

(There is a lot of OpenStack-specific stuff here, so if you've found this repo while looking for how to upgrade a generic CentOS 6 host, be aware of that.)

# Playbook and Scripts

- **`playbook_cent7_upgrade.yaml`** - playbook for orchestrating everything
- **`cent7-upgrade.sh`** - Phase 1 script for configuring prerequisites and getting everything lined up
- **`cent7-afterreboot.sh`** - Phase 2 script that runs after the system first boots after the upgrade is done.  It's main purpose is to upgrade the Spacewalk/yum client packages and prepare the server to transition to the CentOS 7 channels in Spacewalk
- **`cent7-afterspacewalk.sh`** - Phase 3 script which handles doing all the final cleanup and upgrade steps

See the source of each of those scripts for more details and comments to see what they're doing.

# Upgrade Procedure

The playbook will do all the work (as long as nothing goes wrong!):

```
./playbook_cent7_upgrade.yaml -e 'hosts=<hypervisor fqdn>'
```

Basic task flow:

1. Sanity check the current state of packages on the machine (you'll need to provide a sorted package list file for the comparison)
2. Set maintenance mode in monitoring systems (these commands are removed here since they are very specific to Go Daddy)
3. Disable the nova-compute agent
4. Record a list of VMs running on the hypervisor
5. Run the `cent7-upgrade.sh` phase 1 script
6. Sanity check that everything was configured properly to kick off the upgrade
7. 5 minute sanity check pause (OK to cancel early with ctrl-c + c)
8. Reboot the server to kick off the upgrade and wait for server to come back online
9. Run the `cent7-afterreboot.sh` phase 2 script
10. Call Spacewalk API to move server to CentOS 7 base channel
11. Run the `cent7-afterspacewalk.sh` phase 3 script
12. Sanity check the GRUB 2 bootloader was properly installed and configured
13. 5 minute sanity check pause (OK to cancel early with ctrl-c + c)
14. Reboot the server to boot into the latest kernel and wait for server to come back online
15. Run Puppet (twice) to lay down all the OpenStack bits for CentOS 7
16. Run server spec tests to validate everything is good
17. Pause for 180 seconds to allow time for nova-compute agent to restart all the VMs (DO NOT cancel this one early!)
18. Wait for the nova-compute agent to come back online (check in with the control plane)
19. Verify that all VMs have been restarted
20. Enable the nova-compute agent
21. Clear maintenance mode in monitoring systems (these commands are removed here since they are very specific to Go Daddy)

# Background

We originally looked to the [CentOS upgrade tool](https://wiki.centos.org/TipsAndTricks/CentOSUpgradeTool) to handle the upgrade from 6 to 7, and the procedure here does use that tool.  This is a good starting point, but there is more work you will have to do.  It'll do it's best to figure things out, but most likely you will have to do some cleanup work for yourself.

Basically I'd recommend going through the process described on the [CentOS upgrade tool wiki](https://wiki.centos.org/TipsAndTricks/CentOSUpgradeTool).  The pre-upgrade script will do a pretty good job of showing you stuff you'll need to fix before, or after, the upgrade.  More or less you just have to try it on one system, figure out what breaks, how to fix it, and then script together the command history so you can automate it for other hosts.

# Problems we had that you should watch for

### Upgrade tool doesn't configure an initrd in grub for the el7 kernel

This is a big problem, because it'll cause the system to hang after the reboot when the upgrade is done.  What we did was drop in a script to `/root/preupgrade/postupgrade.d` which runs after the upgrade work has been done, but before the reboot.  The script fixes up grub.conf to have the appropriate initrd setting, so the system will actually boot properly.

### systemd Ethernet device naming

Under CentOS 7/systemd, the naming of ethernet NICs changes from the ethN scheme to "predictable device naming" (which in my opinion is not that predictable.)  (See [these](http://www.freedesktop.org/wiki/Software/systemd/PredictableNetworkInterfaceNames/) two  [posts](https://major.io/2015/08/21/understanding-systemds-predictable-network-device-names/) for details)  In any case, you need to change the network configuration with the new device names to handle this.

We handled this by (shimming in the necessary network reconfiguration commands into `/etc/rc.local`)[], which get ran when the host reboots after the upgrade is completed.  See [cent7-upgrade.sh]() for details.  Note also that our hosts are using Open vSwitch (since they are OpenStack hypervisors), so you'll need to adjust the network configuration according to your particular setup.  You will probably want to make sure the `biosdevname` package is installed to make the device naming a little simpler.

### VMs go to SHUTDOWN state after upgrade is completed

This one is OpenStack specific.  Make sure that the `nova-compute` agent is stopped on the host before suspending the VMs via stopping the `libvirt-guests` service.  Otherwise, `nova-compute` will see the VMs shutting down, and will change their state within nova.  This means that after the upgrade is said and done, nova will not restart those VMs and you'll have to do it manually.

As long as you stop `nova-compute` before shutting down/suspending the VMs when rebooting for the upgrade, and you have `resume_guests_state_on_host_boot=True` in `nova.conf`, then `nova-compute` will handle starting the VMs back up automatically when the upgrade is all done.

### Maintain symlinks for el6 versions of some libraries

Some libraries from CentOS 6 will need to be maintained, at least temporarily, to support binaries that don't get properly updated to the CentOS 7 version (see below.)  In particular, I saw this happen for `libsasl2.so.2` and `libpcre.so.0`.  What you can do is just symlink these to the newer CentOS 7 versions. (And hopefully you'll get lucky and this will just work.  It does for libsasl2 and libpcre.):

```
cd /lib64
[ ! -e libsasl2.so.2 ] && ln -s libsasl2.so.3 libsasl2.so.2
[ ! -e libpcre.so.0 ] && ln -s libpcre.so.1.2.0 libpcre.so.0
```

### Some CentOS 6 packages not upgraded due to lower version number in base CentOS 7 repo

The [CentOS upgrade tool wiki](https://wiki.centos.org/TipsAndTricks/CentOSUpgradeTool) calls this out, too, but there are several packages which currently have higher version numbers under the latest CentOS 6 updates than they do in the base CentOS 7 repo.  Therefore, they are not upgraded, and you're left with the old CentOS 6 versions.

The best way I've been able to deal with this is by identifying these packages with `rpm -qa | grep el6`, removing them with `rpm -e --nodeps`, and reinstalling using `yum install`, which will get the CentOS 7 versions.

But, you have to be a little careful with this, because you will seriously break things by removing a package which provides libraries that other things depend on.  (For example, elfutils.)  You can accomplish this this `rpm -e --justdb --nodeps` and then reinstalling with `yum install`

You'll have to do some trial and error on this to figure out the right ordering to do this work such that to keep everything working and get all the dependencies resolved.

### Some CentOS 6 packages not upgraded because they do not exist in CentOS 7

You'll notice some CentOS 6 packages left over that don't have equivalent packages in CentOS 7.  As long as those are not needed to fulfill dependencies for something else, you should be safe to just remove them.  This may also unblock dependencies on other CentOS 6 packages that you would like to upgrade to CentOS 7, but can't because of the dependencies on the old CentOS 6 packages.

### Use `yum check dependencies` as a sanity check

If you can get to a point where `yum check dependencies` shows up as clear, then you're probably mostly good.  That command can give you some good clues as far as which packages to look at next for fixing.

### Need to install the grub 2 bootloader

CentOS 7 uses grub version 2, and that package does get installed by this upgrade.  But, it does not actually install the bootloader bits onto the MBR of the disk.  So you'll need to do this manually.  Otherwise, any time you upgrade kernels, the legacy grub 0.94 config will not be updated.

Details on how to install grub 2 are detailed in this post: http://www.dorm.org/blog/installing-grub2-on-gpt-disks-after-el6-to-el7-upgrade/
