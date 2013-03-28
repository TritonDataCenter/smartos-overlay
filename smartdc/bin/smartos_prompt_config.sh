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
declare -a disks
declare -a show_disks
declare -a existing_pools
declare -a used_disks
SPARE=""
layout=""

sigexit()
{
	echo
	echo "System configuration has not been completed."
	echo "You must reboot to re-run system configuration."
	exit 0
}

#
# Get the max. IP addr for the given field, based in the netmask.
# That is, if netmask is 255, then its just the input field, otherwise its
# the host portion of the netmask (e.g. netmask 224 -> 31).
# Param 1 is the field and param 2 the mask for that field.
#
max_fld()
{
	if [ $2 -eq 255 ]; then
		fmax=$1
	else
		fmax=$((255 & ~$2))
	fi
}

#
# Converts an IP and netmask to a network
# For example: 10.99.99.7 + 255.255.255.0 -> 10.99.99.0
# Each field is in the net_a, net_b, net_c and net_d variables.
# Also, host_addr stores the address of the host w/o the network number (e.g.
# 7 in the 10.99.99.7 example above).  Also, max_host stores the max. host
# number (e.g. 10.99.99.254 in the example above).
#
ip_netmask_to_network()
{
	IP=$1
	NETMASK=$2

	OLDIFS=$IFS
	IFS=.
	set -- $IP
	net_a=$1
	net_b=$2
	net_c=$3
	net_d=$4
	addr_d=$net_d

	set -- $NETMASK

	# Calculate the maximum host address
	max_fld "$net_a" "$1"
	max_a=$fmax
	max_fld "$net_b" "$2"
	max_b=$fmax
	max_fld "$net_c" "$3"
	max_c=$fmax
	max_fld "$net_d" "$4"
	max_d=$(expr $fmax - 1)
	max_host="$max_a.$max_b.$max_c.$max_d"

	net_a=$(($net_a & $1))
	net_b=$(($net_b & $2))
	net_c=$(($net_c & $3))
	net_d=$(($net_d & $4))

	host_addr=$(($addr_d & ~$4))
	IFS=$OLDIFS
}

# Tests whether entire string is a number.
isdigit ()
{
	[ $# -eq 1 ] || return 1

	case $1 in
  	*[!0-9]*|"") return 1;;
	*) return 0;;
	esac
}

# Tests network numner (num.num.num.num)
is_net()
{
	NET=$1

	OLDIFS=$IFS
	IFS=.
	set -- $NET
	a=$1
	b=$2
	c=$3
	d=$4
	IFS=$OLDIFS

	isdigit "$a" || return 1
	isdigit "$b" || return 1
	isdigit "$c" || return 1
	isdigit "$d" || return 1

	[ -z $a ] && return 1
	[ -z $b ] && return 1
	[ -z $c ] && return 1
	[ -z $d ] && return 1

	[ $a -lt 0 ] && return 1
	[ $a -gt 255 ] && return 1
	[ $b -lt 0 ] && return 1
	[ $b -gt 255 ] && return 1
	[ $c -lt 0 ] && return 1
	[ $c -gt 255 ] && return 1
	[ $d -lt 0 ] && return 1
	# Make sure the last field isn't the broadcast addr.
	[ $d -ge 255 ] && return 1
	return 0
}

# Optional input
promptopt()
{
	val=
	printf "%s [press enter for none]: " "$1"
	read val
}

promptval()
{
	val=""
	def="$2"
	while [ -z "$val" ]; do
		if [ -n "$def" ]; then
			printf "%s [%s]: " "$1" "$def"
		else
			printf "%s: " "$1"
		fi
		read val
		[ -z "$val" ] && val="$def"
		[ -n "$val" ] && break
		echo "A value must be provided."
	done
}

# Input must be a valid network number (see is_net())
promptnet()
{
	val=""
	def="$2"
	while [ -z "$val" ]; do
		if [ -n "$def" ]; then
			printf "%s [%s]: " "$1" "$def"
		else
			printf "%s: " "$1"
		fi
		read val
		[ -z "$val" ] && val="$def"
    if [[ "$val" != "dhcp" ]]; then
		  is_net "$val" || val=""
    fi
		[ -n "$val" ] && break
		echo "A valid network number (n.n.n.n) or 'dhcp' must be provided."
	done
}

printnics()
{
	i=1
	printf "%-6s %-9s %-18s %-7s %-10s\n" "Number" "Link" "MAC Address" \
	    "State" "Network"
	while [ $i -le $nic_cnt ]; do
		printf "%-6d %-9s %-18s %-7s %-10s\n" $i ${nics[$i]} \
		    ${macs[$i]} ${states[$i]} ${assigned[i]}
		((i++))
	done
}

# Must choose a valid NIC on this system
promptnic()
{
	if [[ $nic_cnt -eq 1 ]]; then
		val="${macs[1]}"
		return
	fi

	printnics
	num=0
	while [ /usr/bin/true ]; do
		printf "Enter the number of the NIC for the %s interface: " \
		   "$1"
		read num
		if ! [[ "$num" =~ ^[0-9]+$ ]] ; then
			echo ""
		elif [ $num -ge 1 -a $num -le $nic_cnt ]; then
			mac_addr="${macs[$num]}"
			assigned[$num]=$1
			break
		fi
		# echo "You must choose between 1 and $nic_cnt."
		updatenicstates
		printnics
	done

	val=$mac_addr
}

promptpw()
{
	while [ /usr/bin/true ]; do
		val=""
		while [ -z "$val" ]; do
			printf "%s: " "$1"
			stty -echo
			read val
			stty echo
			echo
			if [ -n "$val" ]; then
				if [ "$2" == "chklen" -a ${#val} -lt 6 ]; then
					echo "The password must be at least" \
					    "6 characters long."
					val=""
				else
	 				break
				fi
			else 
				echo "A value must be provided."
			fi
		done

		cval=""
		while [ -z "$cval" ]; do
			printf "%s: " "Confirm password"
			stty -echo
			read cval
			stty echo
			echo
			[ -n "$cval" ] && break
			echo "A value must be provided."
		done

		[ "$val" == "$cval" ] && break

		echo "The entries do not match, please re-enter."
	done
}

printdisks()
{
	
	echo "#   TYPE        DISK    VID   PID        SIZE           REMV      SSD"
 	
	i=1

 	while [ $i -le $disk_cnt ]; do 
		if [[ -z ${used_disks[${i}]} ]]; then
			 echo "$i  ${show_disks[$i]}"
 		fi
		((i++)) 
 	done

}

existing_pool()
{
	/usr/sbin/zpool import -f -a
    existing_pools=$(/usr/sbin/zpool list -H)
    if [[ ${existing_pools} != "" ]]; then 
		
		if [[ ${existing_pools} == *"zones"* ]]; then
			echo -n "zones pool already exists, do you still wish to continue? (y/N): "
			read zonescont
			if [[ ${zonescont} == 'y' || ${zonescont} == 'Y' ]]; then

				echo "pools exist: "
				echo
				echo "---------------------------------------------------------------------"
				/usr/sbin/zpool list -v
				echo "---------------------------------------------------------------------"
				echo
				echo "Choosing drives currently in pools will result in the existing pool"
				echo "becoming degraded, non-functional, or destroyed."
				echo
				echo "Press ENTER continue."
				read
				echo
	
			else
				exit 0
			fi
		fi
    fi
}


promptzpooltype()
{
    existing_pool
   
		printdisks   
	   
		echo
		echo "Chose a zpool layout"
		echo "----------------------"

		#layout number
		lo=0
		
		if [[ ${disk_cnt} > 0 ]]; then
		        ((lo++))
		        echo "${lo}  single"
		        layout[${lo}]="single"
		fi
		
		if [[ ${disk_cnt} > 1 ]]; then
		        ((lo++))
				echo "${lo}  mirror"
		        layout[${lo}]="mirror"
		fi

		if [[ ${disk_cnt} > 2 ]]; then
		        ((lo++))
		        echo "${lo}  mirror with hot spare"
		        layout[${lo}]="mirrorhot"
		        
				((lo++))
				echo "${lo}  raidz"
		        layout[${lo}]="raidz"
		fi

		if [[ ${disk_cnt} > 3 ]]; then
			((lo++))
		   	echo "${lo}  raidz with hot spare"
			layout[${lo}]="raidzhot"
			
		fi
		
		if [[ ${disk_cnt} > 5 ]]; then
			((lo++))
			echo "${lo}  raidz2"
			layout[${lo}]="raidz2"

		fi

		echo "q  Do not select zpool layout, quit installer"
		
	while [[ /usr/bin/true ]]; do
		echo
		echo -n "Please select a storage pool type: "
		read pval
	
	   numele=( ${pval} )
	   
       if [[ ${pval} == "q" ]]; then exit 0; fi;
		   
       if [[ ${pval} == "" ]]; then
         continue
       fi
	   
       	if [[ -z ${pval} ]]; then 
			continue 
		fi
		
		if [[ ${#numele[@]} -ne 1 || ${pval} -lt 1 || ${pval} -gt ${lo} ]]; then
         	echo "Layout ${pval} is not a valid choice"
			continue
	 	fi
		
		pool_layout=${layout[$pval]}
        
		 break
   	
     done 
	
}



promptdisk()
{

	# error check val, undef raid element?

	spare=""
	printdisks
	echo "q  Do not select disks, quit installer"
	echo
	
	if [[ ${pool_layout} == "single" ]]; then
		while [[ /usr/bin/true ]]; do
			echo -n "Please select 1 disk: "
			read dval
			checkdisks 1 0
			ret=$?
			if [[ ${ret} -eq 0 ]]; then 
				break
			fi
		done
	fi
	
	if [[ ${pool_layout} == "mirror" || ${pool_layout} == "mirrorhot" ]]; then
		while [[ /usr/bin/true ]]; do
			echo -n "Please select 2 disks to mirror separated by space: "
			read dval
			checkdisks 2 0
			ret=$?
			if [[ ${ret} -eq 0 ]]; then 
				break
			fi
		done
	fi
	
	if [[ ${pool_layout} == "raidz" || ${pool_layout} == "raidzhot" ]]; then
		while [[ /usr/bin/true ]]; do
			echo -n "Please select at least 3 disks for raidz separated by space: "
			read dval
			checkdisks 3 1
			ret=$?
			if [[ ${ret} -eq 0 ]]; then 
				break
			fi
		done
	fi
	
	if [[ ${pool_layout} == "mirrorhot" || ${pool_layout} == "raidzhot" ]]; then
		printheader "Storage"
		printdisks
		echo
		while [[ /usr/bin/true ]]; do
			spare="yes"
			echo -n "Please select hot spare: "
			read dval
			checkdisks 1 0
			ret=$?
			if [[ ${ret} -eq 0 ]]; then break; fi
		done
	fi
	
	if [[ ${pool_layout} == "raidz2" ]]; then
		while [[ /usr/bin/true ]]; do
			echo -n "Please select at least 6 disks for raidz2 separated by space: "
			read dval
			checkdisks 6 1
			ret=$?
			if [[ ${ret} -eq 0 ]]; then break; fi
		done
	fi
 

}

checkdisks()
{
	reqnum=$1
	ormore=$2
	
	   
    if [[ $dval == "q" ]]; then exit 0; fi
		   
    if [[ $dval == "" ]]; then
      echo "At least one disk must be specified"
      echo ""
    fi
	
	numele=( ${dval} )
	
	if [[ ${ormore} != 0 ]]; then
		if [[ ${reqnum} -gt ${#numele[@]} ]]; then
			echo "Wrong number of disks, select at least ${reqnum}"
			return 1
		fi
	else
		if [[ ${reqnum} -ne ${#numele[@]} ]]; then
			echo "Wrong number of disks, ${reqnum} disks needed"
			return 1
		fi
	fi
	
	# are these the disks we're looking for?
	bad=""
    for n in ${dval}; do
      if [[ -z $n ]]; then continue; fi;		  
      if [[ -z ${disks[$n]}  || ! -z ${used_disks[$n]} ]]; then
        bad="$n $bad"
      else
		  if [[ ${spare} != "" ]]; then
			  SPARE=${disks[$n]}
		  else
			  DISK_LIST=$DISK_LIST" "${disks[$n]}
			  used_disks[${n}]=${disks[${n}]}
	   	  fi
      fi
 	done 
    if [[ $bad != "" ]]; then
      printf "Disk %s is not a valid choice\n\n" $bad
	  if [[ ${spare} == "" ]]; then
		  unset used_disks
		  DISK_LIST=""
	  fi
      
	  return 1
  fi
	
	return 0
}

create_zpool()
{
    disks=$1
    pool=zones

    disk_count=$(echo "${disks}" | wc -w | tr -d ' ')
  
	if [[ ${pool_layout} == "single" ]]; then
		zpool_args="${disks}"
	fi
	
	if [[ ${pool_layout} == "mirror" || ${pool_layout} == "mirrorhot" ]]; then
		zpool_args="mirror ${disks}"
	fi
	
	if [[ ${pool_layout} == "raidz" || ${pool_layout} == "raidzhot" ]]; then
		zpool_args="raidz ${disks}"
	fi
	
	if [[ ${pool_layout} == "mirrorhot" || ${pool_layout} == "raidzhot" ]]; then
		zpool_args="${zpool_args} spare ${SPARE}"
	fi
	
	if [[ ${pool_layout} == "raidz2" ]]; then
		zpool_args="raidz2 ${disks}"
	fi

	# export anything imported
    if [[ $existing_pools != "" ]]; then
    	for found_pool in $(/usr/sbin/zpool list -H | cut -f1); do
			printf "%-56s" "Exporting pool: ${found_pool}..."
        	/usr/sbin/zpool export -f ${found_pool}
			printf "%4s\n" "done"
    	done
	fi
	
	printf "%-56s" "Creating pool $pool... " 
	#echo "zpool create -f ${pool} ${zpool_args}"
	
    zpool create -f ${pool} ${zpool_args} || \
        fatal "failed to create pool ${pool}"
    zfs set atime=off ${pool} || \
        fatal "failed to set atime=off for pool ${pool}"

    printf "%4s\n" "done" 
}

create_zfs()
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



updatenicstates()
{
	states=(1)
	#states[0]=1
	while IFS=: read -r link state ; do
		states=( ${states[@]-} $(echo "$state") )
	done < <(dladm show-phys -po link,state 2>/dev/null)
}

printheader() 
{
  local newline=
  local cols=`tput cols`
  local subheader=$1
  
  if [ $cols -gt 80 ] ;then
    newline='\n'
  fi
  
  clear
  for i in {1..80} ; do printf "-" ; done && printf "$newline"
  printf " %-40s\n" "SmartOS Setup"
  printf " %-40s%38s\n" "$subheader" "http://wiki.smartos.org/install"
  for i in {1..80} ; do printf "-" ; done && printf "$newline"

}

getdisks()
{
	
	disk_cnt=0

	# diskinfo currently cant print just nonremovable drives
	# fields in diskinfo may have multiple words making parsing uncertain

	# get nonremovable drives from disklist, then key off those getting more
	# info from diskinfo
	
	for disk in $(disklist -n); do
		((disk_cnt++))
		disks[$disk_cnt]=$disk
		while read di_disk; do
			if [[ ${di_disk} == *${disk}* ]]; then
				show_disks[$disk_cnt]=$di_disk
			fi
		done < <(diskinfo -H)
	done
}

trap sigexit SIGINT

#
# Get local NIC info
#
nic_cnt=0

while IFS=: read -r link addr ; do
    ((nic_cnt++))
    nics[$nic_cnt]=$link
    macs[$nic_cnt]=`echo $addr | sed 's/\\\:/:/g'`
    assigned[$nic_cnt]="-"
done < <(dladm show-phys -pmo link,address 2>/dev/null)

if [[ $nic_cnt -lt 1 ]]; then
	echo "ERROR: cannot configure the system, no NICs were found."
	exit 0
fi

ifconfig -a plumb
updatenicstates

#
# Get nonremoveable disk info
#

getdisks

	
	
export TERM=sun-color
export TERM=xterm-color
stty erase ^H

printheader "Copyright 2011, Joyent, Inc."

message="
You must answer the following questions to configure the system.
You will have a chance to review and correct your answers, as well as a
chance to edit the final configuration, before it is applied.

Would you like to continue with configuration? [Y/n]"

printf "$message"
read continue;
if [[ $continue == 'n' ]]; then
	exit 0
fi
#
# Main loop to prompt for user input
#
while [ /usr/bin/true ]; do

	printheader "Networking" 
	
	promptnic "'admin'"
	admin_nic="$val"

	admin_ip="dhcp"
	promptnet "IP address (or 'dhcp' )" "$admin_ip"
	admin_ip="$val"
  if [[ $admin_ip != 'dhcp' ]]; then
    promptnet "netmask" "$admin_netmask"
    admin_netmask="$val"

    printheader "Networking - Continued"
    message=""
    
    printf "$message"

    message="
  The default gateway will determine which network will be used to connect to
  other networks.\n\n"

    printf "$message"

    promptnet "Enter the default gateway IP" "$headnode_default_gateway"
    headnode_default_gateway="$val"

    promptval "Enter the Primary DNS server IP" "$dns_resolver1"
    dns_resolver1="$val"
    promptval "Enter the Secondary DNS server IP" "$dns_resolver2"
    dns_resolver2="$val"
    promptval "Enter the domain name" "$domainname"
    domainname="$val"
    promptval "Default DNS search domain" "$dns_domain"
    dns_domain="$val"
  fi	
  
  	#######
  
  
	printheader "Storage"
	promptzpooltype
	printheader "Storage"
 	promptdisk
 
	########
	printheader "Account Information"
	
	promptpw "Enter root password" "nolen"
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
	promptval "Is this correct?" "y"
	[ "$val" == "y" ] && break
	clear
done
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
echo "Your configuration is about to be applied."
promptval "Would you like to edit the final configuration file?" "n"
[ "$val" == "y" ] && vi $tmp_config
clear

printheader "Confirm Storage"
echo "Your ${pool_layout%hot} data pool will be created with the following disks:"
echo

#echo $DISK_LIST


for d in ${DISK_LIST}; do
	i=1;
 	while [ $i -le $disk_cnt ]; do 
			if [[ "${show_disks[$i]}" == *"${d}"* ]]; then
				echo ${show_disks[$i]}
			fi
			((i++))
	done
done


if [[ ${SPARE} != "" ]]; then
	echo
	echo "With the following disk as spare:"
	echo

#echo ${SPARE}

	i=1
	 	while [ $i -le $disk_cnt ]; do 
				if [[ "${show_disks[$i]}" == *"${SPARE}"* ]]; then
					echo ${show_disks[$i]}
				fi
				((i++))
		done

fi

using_existing=""
echo
for p in $(/usr/sbin/zpool list -H | cut -f1); do
	for l in $(/usr/sbin/zpool list -v $p); do
		for d in $DISK_LIST; do
			if [[ "$l" == *"$d"* ]]; then
				using_existing="yes"
				echo "**************************"
				echo "* $d member of zpool $p. *"
				echo "**************************"
				echo
			fi
		done
	done
done
if [[ $using_existing != "yes" ]]; then
	
	
	echo "*********************************************"
	echo "* This will erase *ALL DATA* on these disks *"
	echo "*********************************************"
	echo
fi

promptval "are you sure?" "n"
[ "$val" == "y" ] && (create_zfs "$DISK_LIST")

clear
echo "The system will now finish configuration and reboot. Please wait..."
mv $tmp_config /usbkey/config

# set the root password
root_shadow=$(/usr/lib/cryptpass "$root_shadow")
sed -e "s|^root:[^\:]*:|root:${root_shadow}:|" /etc/shadow > /usbkey/shadow \
      && chmod 400 /usbkey/shadow

cp -rp /etc/ssh /usbkey/ssh

reboot
