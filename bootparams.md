The following values can be passed as boot parameters to control the behaviour of the install script and provide values for the configuration.

## purge
When purge is set the installer will boot into single user mode, import the given zpools and destroy them, this is a automated way to delete a SmartOS installation.

### Possible values
Colon separated list of zpools do purge.

### Example
```
purge=zones,data
```

## unattended
When set the installer will not enter interactive mode but read all options from the boot params, all the following options will have no effect.

### Possible values
* true

### Example
```
unattended=true
```

## disks
The disks used for the zpool.

### Possible values
* `all` - uses all available disks
* Colon sepperated list of disks

### Example
```
disks=all
disks=c0t0d0,c1t0d0
```

## pool_profile
The raid(z) profile used to create the pool, this is automatically decided during the interactive installation based on the number of the disks. The original behaviour can be used by passing `auto`.

### Possible values
* auto - original behavior
* raidz - forces raidZ
* mirror - forces a stripe of mirrors containing two disks each
* raid10+2 - same as mirror but declares two disks as spare.

### Example
```
pool_profile=raid10+2
pool_profile=auto
```

## admin_nic
Interface used for the admin network, this is **not** the MAC address of the interface but the name.

### Possible values
Name of a interface, i.e. `igb0`.

### Example
```
admin_nic=igb0
```

## admin_ip
The IP Address of the admin interface.


### Possible values
* a valid IPv4
* `dhcp`

### Example
```
admin_ip=10.0.0.42
admin_ip=dhcp
```

## admin_netmask
The netmask of the admin interface. This is ignored if admin_ip is `dhcp`.


### Possible values
* a valid IPv4

### Example
```
admin_netmask=255.255.255.0
```

## gateway
The systems default gateway. This is ignored if admin_ip is `dhcp`.

### Possible values
* a valid IPv4

### Example
```
admin_netmask=10.0.0.1
```

## dns1 / dns2
The systems DNS servers. This is ignored if admin_ip is `dhcp`.

### Possible values
* a valid IPv4


### Example
```
dns1=10.0.0.1
dns2=8.8.8.8
```

## domain
The systems domain name. This is ignored if admin_ip is `dhcp`.

### Possible values
* a valid domain


### Example
```
domain=local
```

## search_domain
The systems search domain. This is ignored if admin_ip is `dhcp`.


### Possible values
* a valid domain


### Example
```
search_domain=local
```


## root_pw
The root password for the system, in clear text.

### Possible values
* random - a random 32 char root password will be created and written to /usbkey
* any password


### Example
```
root_pw=random
root_pw=not_random
```

## run_script
A URL for a bash script to be executed after the installer has finished, this script can modify the system, add values to the config or do whatever it wants. If this parameter is given the installer will bring up the admin_nic 'manually' to download the script and execute it.

### Possible values
* Any URL that is reachable with the admin_ network configuraiton

### Example
```
run_script=http://10.0.0.1/bootstrap/init.sh
```
