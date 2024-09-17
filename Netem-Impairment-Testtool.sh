#!/bin/bash
# Steve Voto & Duc PHAN - Juniper
# Network disturbance simulation script for Juniper SSR tests

# Log file name
LOG_FILE="./ssr_test_v4.log"

# Logging function
log() {
    local message=$1
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" | tee -a $LOG_FILE
}

# Function to check and install a package if the associated command is missing
check_and_install() {
    local cmd=$1
    local pkg=$2
    if ! command -v $cmd &> /dev/null
    then
        log "$cmd is required, installing package $pkg..."
        sudo apt-get update | tee -a $LOG_FILE
        sudo apt-get install -y $pkg | tee -a $LOG_FILE
    fi
}

# Check and install necessary packages
check_and_install tc iproute2         # For tc and ip commands
check_and_install dialog dialog       # For interactive dialog boxes
check_and_install brctl bridge-utils  # For bridge management
check_and_install dhclient isc-dhcp-client # For DHCP management
check_and_install ifb ifb             # For the virtual ifb interface

# Function to check and remove any IP address on an interface (bridge, physical interface, or ifb)
check_and_flush_ip() {
    local interface=$1
    if [[ -z $interface ]]; then
        log "Error: Interface not specified in check_and_flush_ip"
        return
    fi
    log "Checking IP addresses on $interface"
    interface_ip=$(ip addr show dev $interface | grep "inet\b" | awk '{print $2}')
    if [ -n "$interface_ip" ]; then
        log "The interface $interface has an IP address ($interface_ip). Removing the IP address..."
        sudo ip addr flush dev $interface | tee -a $LOG_FILE
        log "IP address removed from the interface $interface."
    else
        log "The interface $interface has no IP address."
    fi
}

# Function to remove all TC rules (Netem and TBF) on enp1s0 and ifb0
clear_all_tc_rules() {
    local interface1="enp1s0"
    local interface_ifb="ifb0"
    log "Removing all TC rules on $interface1 and $interface_ifb (Netem and TBF)"
    sudo tc qdisc del dev $interface1 root 2>/dev/null || log "Error removing TC rules on $interface1"
    sudo tc qdisc del dev $interface_ifb root 2>/dev/null || log "Error removing TC rules on $interface_ifb"
}

# Function to configure ifb and redirect incoming traffic
configure_ifb() {
    log "Configuring ifb for incoming traffic (download)"
    sudo modprobe ifb || log "Error: ifb module not found"
    sudo ip link add ifb0 type ifb || log "Error creating ifb0"
    sudo ip link set ifb0 up || log "Error activating ifb0"
    sudo tc qdisc add dev enp1s0 handle ffff: ingress || log "Error adding ingress qdisc on enp1s0"
    sudo tc filter add dev enp1s0 parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0 || log "Error redirecting to ifb0"
}

# Function to apply Netem parameters (packet loss, delay, jitter) on both interfaces (enp1s0 and ifb0)
apply_netem_rules() {
    local loss=$1
    local delay=$2
    local jitter=$3
    local interface1="enp1s0"
    local interface_ifb="ifb0"

    log "Applying Netem rules (packet loss, delay, jitter) on $interface1 (upload) and $interface_ifb (download)"
    
    # Apply Netem rules on enp1s0 for outgoing traffic
    tc_command1="tc qdisc add dev $interface1 root handle 1: netem"
    
    if [ -n "$loss" ]; then
        tc_command1="$tc_command1 loss $loss%"
    fi
    if [ -n "$delay" ]; then
        tc_command1="$tc_command1 delay ${delay}ms"
        if [ -n "$jitter" ]; then
            tc_command1="$tc_command1 ${jitter}ms"
        fi
    fi
    
    # Apply Netem rules on ifb0 for incoming traffic
    tc_command2="tc qdisc add dev $interface_ifb root handle 1: netem"
    
    if [ -n "$loss" ]; then
        tc_command2="$tc_command2 loss $loss%"
    fi
    if [ -n "$delay" ]; then
        tc_command2="$tc_command2 delay ${delay}ms"
        if [ -n "$jitter" ]; then
            tc_command2="$tc_command2 ${jitter}ms"
        fi
    fi
    
    # Execute Netem commands for enp1s0
    if [ "$tc_command1" != "tc qdisc add dev $interface1 root handle 1: netem" ]; then
        log "Netem command for $interface1: $tc_command1"
        $tc_command1 || log "Error applying Netem command on $interface1"
    else
        log "No Netem rule specified for $interface1."
    fi
    
    # Execute Netem commands for ifb0
    if [ "$tc_command2" != "tc qdisc add dev $interface_ifb root handle 1: netem" ]; then
        log "Netem command for $interface_ifb: $tc_command2"
        $tc_command2 || log "Error applying Netem command on $interface_ifb"
    else
        log "No Netem rule specified for $interface_ifb."
    fi
}

# Function to apply bandwidth limitation using tbf
apply_bandwidth_limit() {
    local bandwidth=$1
    local interface="enp1s0"
    local interface_ifb="ifb0"

    if [ -n "$bandwidth" ]; then
        log "Limiting bandwidth to $bandwidth Mbps on $interface with a burst of 32kbit and latency of 10ms (upload)"
        sudo tc qdisc add dev $interface parent 1: tbf rate ${bandwidth}mbit burst 32kbit latency 10ms || log "Error adding tbf rule on $interface"

        log "Limiting bandwidth to $bandwidth Mbps on $interface_ifb with a burst of 32kbit and latency of 10ms (download)"
        sudo tc qdisc add dev $interface_ifb parent 1: tbf rate ${bandwidth}mbit burst 32kbit latency 10ms || log "Error adding tbf rule on $interface_ifb"
    else
        log "No bandwidth limitation specified."
    fi
}

# Function to display the queue status of the interfaces
display_tc_status() {
    log "Refreshing interface queues"
    sudo tc qdisc show dev $interface1
    sudo tc qdisc show dev $interface_ifb
    sudo tc qdisc show dev $bridge

    # Display current impact on the three interfaces (enp1s0, ifb0, bridge)
    result_enp1s0=$(tc qdisc show dev $interface1)
    result_ifb0=$(tc qdisc show dev $interface_ifb)
    result_bridge=$(tc qdisc show dev $bridge)
    
    log "Current impact on interface $interface1: $result_enp1s0"
    log "Current impact on interface $interface_ifb: $result_ifb0"
    log "Current impact on bridge $bridge: $result_bridge"

    result="Interface $interface1:\n$result_enp1s0\n\nInterface $interface_ifb:\n$result_ifb0\n\nBridge $bridge:\n$result_bridge"
    display_result "$result"
}

DIALOG_CANCEL=1
DIALOG_ESC=255
HEIGHT=30
WIDTH=60

# Interfaces used
interface1="enp1s0"
interface2="enp2s0"
bridge="nm-bridge"
interface_ifb="ifb0"

display_result() {
  dialog --title "$1" \
    --no-collapse \
    --msgbox "$result" 0 0
}

log "Starting WAN disturbance simulation script"

while true; do
  exec 3>&1
  selection=$(dialog \
    --backtitle "** JUNIPER - SSR Testing only **" \
    --title "Menu" \
    --clear \
    --cancel-label "Exit" \
    --menu "Please select:" $HEIGHT $WIDTH 8 \
    1 "Setup Netem Bridge and Impairment" \
    2 "Display Impact on Bridge" \
    3 "Bridge without impairment (Normal Mode)" \
    4 "Delete Bridge Interface and Renew DHCP/DNS" \
    2>&1 1>&3)
  exit_status=$?
  exec 3>&-
  
  case $exit_status in
    $DIALOG_CANCEL)
      log "Program terminated by the user."
      clear
      echo "Program terminated."
      exit
      ;;
    $DIALOG_ESC)
      log "Program aborted by the user."
      clear
      echo "Program aborted." >&2
      exit 1
      ;;
  esac

  case $selection in

    1 )
    log "Selected: Setup Netem Bridge and Impairment"

    # Clear all TC rules
    clear_all_tc_rules
    # Configure the ifb and redirect traffic
    configure_ifb
    # Ask for Netem values
    exec 3>&1
    netem_values=$(dialog --backtitle "Impairment Parameters" \
      --title "Impairment Parameters" \
      --form "Enter impairment values" \
      $HEIGHT $WIDTH 6 \
      "Packet loss (%)" 1 1 "0" 1 25 25 30 \
      "Delay (ms)" 2 1 "0" 2 25 25 30 \
      "Jitter (ms)" 3 1 "0" 3 25 25 30 \
      2>&1 1>&3)
    exec 3>&-
    
    packet_loss=$(echo $netem_values | cut -d " " -f 1)
    delay=$(echo $netem_values | cut -d " " -f 2)
    jitter=$(echo $netem_values | cut -d " " -f 3)

    # Ask for bandwidth limitation
    exec 3>&1
    bandwidth=$(dialog --backtitle "Bandwidth Limitation" \
      --title "Bandwidth Limitation" \
      --inputbox "Enter bandwidth limitation (Mbps):" \
      8 40 2>&1 1>&3)
    exec 3>&-

    # Apply Netem rules
    apply_netem_rules $packet_loss $delay $jitter
    # Apply bandwidth limitation
    apply_bandwidth_limit $bandwidth
    ;;
  
    2 )
    log "Selected: Display Impact on Bridge"
    display_tc_status
    ;;

    3 )
    log "Selected: Bridge without impairment (Normal Mode)"
    clear_all_tc_rules
    ;;
  
    4 )
    log "Selected: Delete Bridge Interface and Renew DHCP/DNS"
    log "Removing bridge $bridge"
    sudo brctl delbr $bridge
    sudo dhclient $interface1
    sudo service networking restart
    ;;
  esac
done
