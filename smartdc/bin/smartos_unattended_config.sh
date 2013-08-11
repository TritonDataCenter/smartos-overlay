#!/usr/bin/bash

# XXX - TODO
# - if $ntp_hosts == "local", configure ntp for no external time source
# - try to figure out why ^C doesn't intr when running under SMF

PATH=/usr/sbin:/usr/bin
export PATH
. /lib/sdc/config.sh
load_sdc_sysinfo
load_sdc_config

# Defaults
datacenter_headnode_id=0
mail_to="root@localhost"
ntp_hosts="pool.ntp.org"
dns_resolver1="8.8.8.8"
dns_resolver2="8.8.4.4"

# Globals
declare -a states
declare -a nics
declare -a assigned
declare -a DISK_LIST

#
# Reads a boot parameters returns the assigned value for a given key.
# If the key is not found an empty string is returned.
# The data is stored in $val.
#
get_bootparam()
{
    val=""
    if /bin/bootparams | grep "^$1=" > /dev/null 2>&1
    then
        val=$(/bin/bootparams | grep "^$1=" | sed "s/^$1=//")
    fi
}

sigexit()
{
    echo
    echo "System configuration has not been completed."
    echo "You must reboot to re-run system configuration."
    exit 0
}

create_dump()
{
    # Get avail zpool size - this assumes we're not using any space yet.
    base_size=`zfs get -H -p -o value available ${SYS_ZPOOL}`
    # Convert to MB
    base_size=`expr $base_size / 1000000`
    # Calculate 5% of that
    base_size=`expr $base_size / 20`
    # Cap it at 4GB
    [ ${base_size} -gt 4096 ] && base_size=4096

    # Create the dump zvol
    zfs create -V ${base_size}mb ${SYS_ZPOOL}/dump || \
        fatal "failed to create the dump zvol"
    dumpadm -d /dev/zvol/dsk/${SYS_ZPOOL}/dump
}

#
# Setup the persistent datasets on the zpool.
#
setup_datasets()
{
    datasets=$(zfs list -H -o name | xargs)

    if ! echo $datasets | grep dump > /dev/null; then
        printf "%-56s" "Making dump zvol... "
        create_dump
        printf "%4s\n" "done"
    fi

    if ! echo $datasets | grep ${CONFDS} > /dev/null; then
        printf "%-56s" "Initializing config dataset for zones... "
        zfs create ${CONFDS} || fatal "failed to create the config dataset"
        chmod 755 /${CONFDS}
        cp -p /etc/zones/* /${CONFDS}
        zfs set mountpoint=legacy ${CONFDS}
        printf "%4s\n" "done"
    fi

    if ! echo $datasets | grep ${USBKEYDS} > /dev/null; then
        if [[ -n $(/bin/bootparams | grep "^smartos=true") ]]; then
            printf "%-56s" "Creating config dataset... "
            zfs create -o mountpoint=legacy ${USBKEYDS} || \
                fatal "failed to create the config dataset"
            mkdir /usbkey
            mount -F zfs ${USBKEYDS} /usbkey
            printf "%4s\n" "done"
        fi
    fi

    if ! echo $datasets | grep ${COREDS} > /dev/null; then
        printf "%-56s" "Creating global cores dataset... "
        zfs create -o quota=10g -o mountpoint=/${SYS_ZPOOL}/global/cores \
            -o compression=gzip ${COREDS} || \
            fatal "failed to create the cores dataset"
        printf "%4s\n" "done"
    fi

    if ! echo $datasets | grep ${OPTDS} > /dev/null; then
        printf "%-56s" "Creating opt dataset... "
        zfs create -o mountpoint=legacy ${OPTDS} || \
            fatal "failed to create the opt dataset"
        printf "%4s\n" "done"
    fi

    if ! echo $datasets | grep ${VARDS} > /dev/null; then
        printf "%-56s" "Initializing var dataset... "
        zfs create ${VARDS} || \
            fatal "failed to create the var dataset"
        printf "%4s\n" "done"
        chmod 755 /${VARDS}
        cd /var
        if ( ! find . -print | cpio -pdm /${VARDS} 2>/dev/null ); then
            fatal "failed to initialize the var directory"
        fi

        zfs set mountpoint=legacy ${VARDS}

        if ! echo $datasets | grep ${SWAPVOL} > /dev/null; then
            printf "%-56s" "Creating swap zvol... "
            #
            # We cannot allow the swap size to be less than the size of DRAM, lest$
            # we run into the availrmem double accounting issue for locked$
            # anonymous memory that is backed by in-memory swap (which will$
            # severely and artificially limit VM tenancy).  We will therfore not$
            # create a swap device smaller than DRAM -- but we still allow for the$
            # configuration variable to account for actual consumed space by using$
            # it to set the refreservation on the swap volume if/when the$
            # specified size is smaller than DRAM.$
            #
            size=${SYSINFO_MiB_of_Memory}
            zfs create -V ${size}mb ${SWAPVOL}
            swap -a /dev/zvol/dsk/${SWAPVOL}
        fi
        printf "%4s\n" "done"
    fi
}

create_zpool()
{
    disks=$1
    pool=zones

    # If the pool already exists, don't create it again.
    if /usr/sbin/zpool list -H -o name $pool; then
        return 0
    fi

    disk_count=$(echo "${disks}" | wc -w | tr -d ' ')
    printf "%-56s" "Creating pool $pool... "

    if [[ "${disk_count}" == "0" ]]
    then
        fatal "no disks found, can't create zpool"
    fi

    # Readthe pool_profile from boot params
    get_bootparam "pool_profile"
    profile="${val}"

    # If no pool profile was provided, use a default based on the number of
    # devices in that pool.
    if [[ -z ${profile} ]]; then
        case ${disk_count} in
            1)
                profile="";;
            2)
                profile=mirror;;
            *)
                profile=raidz;;
        esac
    fi

    zpool_args=""

    # When creating a mirrored pool, create a mirrored pair of devices out of
    # every two disks.
    if [[ ${profile} == "mirror" ]]; then
        ii=0
        for disk in ${disks}; do
            if [[ $(( $ii % 2 )) -eq 0 ]]; then
                zpool_args="${zpool_args} ${profile}"
            fi
            zpool_args="${zpool_args} ${disk}"
            ii=$(($ii + 1))
        done
    elif [[ ${profile} == "raid10+2" ]]
    then
        ii=0
        for disk in ${disks}; do
            if [[ $(( $ii % 2 )) -eq 0 ]]; then
                zpool_args="${zpool_args} mirror"
            fi
            zpool_args="${zpool_args} ${disk}"
            ii=$(($ii + 1))
        done
        # Replace the last mirror with spares so we get two spare disks
        zpool_args=$(echo "${zpool_args}" | sed 's/\(.*\)mirror/\1spare/')
    else
        zpool_args="${profile} ${disks}"
    fi

    zpool create -f ${pool} ${zpool_args} || \
        fatal "failed to create pool ${pool}"
    zfs set atime=off ${pool} || \
        fatal "failed to set atime=off for pool ${pool}"

    printf "%4s\n" "done"
}

create_zpools()
{
    devs=$1

    export SYS_ZPOOL="zones"
    create_zpool "$devs"
    sleep 5

    svccfg -s svc:/system/smartdc/init setprop config/zpool="zones"
    svccfg -s svc:/system/smartdc/init:default refresh

    export CONFDS=${SYS_ZPOOL}/config
    export COREDS=${SYS_ZPOOL}/cores
    export OPTDS=${SYS_ZPOOL}/opt
    export VARDS=${SYS_ZPOOL}/var
    export USBKEYDS=${SYS_ZPOOL}/usbkey
    export SWAPVOL=${SYS_ZPOOL}/swap

    setup_datasets
    #
    # Since there may be more than one storage pool on the system, put a
    # file with a certain name in the actual "system" pool.
    #
    touch /${SYS_ZPOOL}/.system_pool
}


printheader()
{
    local newline=
    local cols=`tput cols`
    local subheader=$1

    if [ $cols -gt 80 ] ;then
        newline='\n'
    fi

    for i in {1..80} ; do printf "-" ; done && printf "$newline"
    printf " %-40s\n" "SmartOS Setup"
    printf " %-40s%38s\n" "$subheader" "http://wiki.smartos.org/install"
    for i in {1..80} ; do printf "-" ; done && printf "$newline"

}

trap sigexit SIGINT

ifconfig -a plumb

export TERM=sun-color
export TERM=xterm-color
stty erase ^H

printheader "Copyright 2011, Joyent, Inc."

#
# Main loop to prompt for user input
#

printheader "Networking"

get_bootparam "admin_nic"

admin_interface=$val
admin_nic=$(dladm show-phys -pmo address ${val})

get_bootparam "admin_ip"
admin_ip="$val"
if [[ $admin_ip != 'dhcp' ]]; then
    get_bootparam "admin_netmask"
    admin_netmask="$val"

    message="
  The default gateway will determine which network will be used to connect to
  other networks.\n\n"

    printf "$message"

    get_bootparam "gateway"
    headnode_default_gateway="$val"

    get_bootparam "dns1"
    dns_resolver1="$val"

    get_bootparam "dns2"
    dns_resolver2="$val"

    get_bootparam "domain"
    domainname="$val"
    get_bootparam "search_domain"
    dns_domain="$val"
fi


get_bootparam "disks"
if [[ $val == "all" ]]; then
    DISK_LIST="$(disklist -n)"
else
    DISK_LIST="${val}"
fi

get_bootparam "root_pw"
if [[ "${val}" == "random" ]]
then
    val=$(cat /dev/urandom | LC_CTYPE=C tr -dc '[:alpha:]0-9$:_+-' | fold -w 32 | head -n 1)
fi
root_shadow="$val"

printheader "Verify Configuration"
message=""

printf "$message"

echo "Verify that the following values are correct:"
echo
echo "MAC address: $admin_nic"
echo "IP address: $admin_ip"
if [[ $admin_ip != 'dhcp' ]]; then
    echo "Netmask: $admin_netmask"
    echo "Gateway router IP address: $headnode_default_gateway"
    echo "DNS servers: $dns_resolver1,$dns_resolver2"
    echo "Default DNS search domain: $dns_domain"
    echo "NTP server: $ntp_hosts"
    echo "Domain name: $domainname"
    echo
fi

admin_network="$net_a.$net_b.$net_c.$net_d"

#
# Generate config file
#
tmp_config=/tmp_config
touch $tmp_config
chmod 600 $tmp_config

echo "#" >$tmp_config
echo "# This file was auto-generated and must be source-able by bash." \
    >>$tmp_config
echo "#" >>$tmp_config
echo >>$tmp_config

# If in a VM, setup coal so networking will work.
platform=$(smbios -t1 | nawk '{if ($1 == "Product:") print $2}')
[ "$platform" == "VMware" ] && echo "coal=true" >>$tmp_config

echo "# admin_nic is the nic admin_ip will be connected to for headnode zones."\
    >>$tmp_config
echo "admin_nic=$admin_nic" >>$tmp_config
echo "admin_ip=$admin_ip" >>$tmp_config
echo "admin_netmask=$admin_netmask" >>$tmp_config
echo "admin_network=$admin_network" >>$tmp_config
echo "admin_gateway=$admin_ip" >>$tmp_config
echo >>$tmp_config

echo "headnode_default_gateway=$headnode_default_gateway" >>$tmp_config
echo >>$tmp_config

echo "dns_resolvers=$dns_resolver1,$dns_resolver2" >>$tmp_config
echo "dns_domain=$dns_domain" >>$tmp_config
echo >>$tmp_config


echo "ntp_hosts=$ntp_hosts" >>$tmp_config

echo "compute_node_ntp_hosts=$admin_ip" >>$tmp_config
echo >>$tmp_config

echo

create_zpools "$DISK_LIST"

echo "The system will now finish configuration and reboot. Please wait..."
mv $tmp_config /usbkey/config


# set the root password
root_shadow=$(/usr/lib/cryptpass "$root_shadow")
sed -e "s|^root:[^\:]*:|root:${root_shadow}:|" /etc/shadow > /usbkey/shadow \
    && chmod 400 /usbkey/shadow

cp -rp /etc/ssh /usbkey/ssh

get_bootparam "run_script"
if [ ! -z $val ]
then
    script=$val
    echo "It was requested to run the script $script ..."
    echo "Setting up network..."
    ifconfig $admin_interface plumb
    if [[ "${admin_ip}" == "dhcp" ]]
    then
        echo "We're using DHCP"
        ifconfig $admin_interface dhcp
    else
        echo "Configuring it manually"
        ifconfig $admin_interface $admin_ip netmask $admin_netmask
        route add default $headnode_default_gateway
        echo "nameserver $dns_resolver1" > /etc/resolv.conf
        echo "nameserver $dns_resolver1" >> /etc/resolv.conf
        echo "domain $domainname" >> /etc/resolv.conf
        echo "search $dns_domain" >> /etc/resolv.conf
        /etc/init.d/nscd stop
        /etc/init.d/nscd start
    fi
    bash <(curl -kL ${script})
fi

reboot
