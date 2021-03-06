#!/bin/sh
# script to create blacklists with ipset for suspicious IPv4 addresses (eg infected hosts)

IP_BLACKLIST=/etc/blacklist.ip.conf
NET_BLACKLIST=/etc/blacklist.net.conf

TEMP_DIR=/tmp/blacklist_temp
WGET_LOG=/tmp/update_blacklist.log
BLACKLISTS="
    http://www.projecthoneypot.org/list_of_ips.php?t=d&rss=1
    http://check.torproject.org/exit-addresses
    http://www.maxmind.com/en/anonymous_proxies
    http://www.spamhaus.org/drop/drop.lasso
    http://danger.rulez.sk/projects/bruteforceblocker/blist.php
    http://www.openbl.org/lists/base.txt
    http://cinsscore.com/list/ci-badguys.txt
    http://www.autoshun.org/files/shunlist.csv
    http://lists.blocklist.de/lists/all.txt
    http://rules.emergingthreats.net/blockrules/emerging-compromised.rules
    http://malc0de.com/bl/IP_Blacklist.ttx
    http://www.dshield.org/ipsascii.html?limit=10000
    http://www.blocklist.de/downloads/export-ips_all.txt
    "
IP_REGEX="([0-9]{1,3}\.){3}[0-9]{1,3}"
RANGE_REGEX="$IP_REGEX ?- ?$IP_REGEX"
CIDR_REGEX="$IP_REGEX/[0-9]{1,2}"
NET_REGEX="($RANGE_REGEX)|($CIDR_REGEX)"

# download multiple URLs and output to stdout (log errors to logfile)
download_lists(){
    # clear the wget log
    echo -n > $WGET_LOG

    # download blacklists
    for i in $*
    do
        (wget --no-check-certificate -O - "$i" 2>> $WGET_LOG) || echo Error downloading $i 1>&2
    done

    return 0
}

# make sure each IP/net is on a separate line and drop unneeded lines
process_raw_list(){
    # make sure each IP/net is on a seperate line
    sed -r 's/,/\n/g' |\
    
    # drop the lines without IP addresses
    grep -E $IP_REGEX || return 1
}

# take a list of IPs or nets on stdin (1 per line) and create & apply an ipset
# arg 1: ipset type
# arg 2: ipset name
create_ipset(){
    # remove duplicate IPs/nets, save to the temp file, and count them
    NUM_ELEMS=`tee $TEMP_DIR/temp_list | wc -l`

    # create the temporary ipset
    if ! ipset create $2_tmp $1 maxelem $NUM_ELEMS; then return 1; fi
    
    # fill the ipset
    cat $TEMP_DIR/temp_list | while IFS= read -r elem
    do
        #echo "adding $elem to $2"
        if ! ipset add $2_tmp $elem ; then return 1; fi
    done
    
    # try to swap the temp ipset with the final ipset. 
    if !(ipset swap $2_tmp $2 >/dev/null 2>&1)
    then
        # if swapping fails, try to rename it
        if ! (ipset rename $2_tmp $2 >/dev/null 2>&1)
        then
            echo Error renaming ipset >&2
            ipset destroy $2_tmp
            return 1
        fi
    fi

    # destroy the old ipset
    if ! ipset destroy $2_tmp; then return 1; fi

    echo Created ipset $2 with $NUM_ELEMS elements
}

# make the temp dir
if ! mkdir -p $TEMP_DIR; then echo Error making temp dir && exit; fi

# download the raw list of suspicious hosts & nets
if ! (download_lists $BLACKLISTS | process_raw_list > $TEMP_DIR/raw); then echo Error downloading blacklists 1>&2 && exit; fi

# create blacklist for IP nets
if ! ((grep -oE "$CIDR_REGEX" $TEMP_DIR/raw | uniq_cidr.lua ;
grep -oE "$RANGE_REGEX" $TEMP_DIR/raw) |\
tee $NET_BLACKLIST |\
create_ipset hash:net blacklist_net); then echo Error creating hash:net blacklist 1>&2 && exit; fi


# create blacklist for individual IP addrs
if ! (grep -vE "$NET_REGEX" $TEMP_DIR/raw |\
grep -oE "$IP_REGEX" |\
normalize_ip.lua |\
sort -u |\
tee $IP_BLACKLIST |\
create_ipset hash:ip blacklist_ip); then echo Error creating hash:ip blacklist 1>&2 && exit; fi


# delete temp dir
rm -rf $TEMP_DIR
