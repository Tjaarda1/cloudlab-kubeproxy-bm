#!/bin/bash

set -x
BASE_IP="10.10.1."
SECONDARY_PORT=3000
INSTALL_DIR=/home/eebpf
PROFILE_GROUP="eebpf"
MULTUS_COMMIT="77e0150"

NUM_MIN_ARGS=3
NUM_PRIMARY_ARGS=4
PRIMARY_ARG="primary"
SECONDARY_ARG="secondary"
USAGE=$'Usage:\n\t./start.sh secondary <node_ip> <start_kubernetes>\n\t./start.sh primary <node_ip> <num_nodes> <start_kubernetes>'

configure_docker_storage() {
    printf "%s: %s\n" "$(date +"%T.%N")" "Configuring docker storage"
    sudo mkdir /mydata/docker
    echo -e '{
        "exec-opts": ["native.cgroupdriver=systemd"],
        "log-driver": "json-file",
        "log-opts": {
            "max-size": "100m"
        },
        "storage-driver": "overlay2",
        "data-root": "/mydata/docker"
    }' | sudo tee /etc/docker/daemon.json
    sudo systemctl restart docker || (echo "ERROR: Docker installation failed, exiting." && exit -1)
    sudo docker run hello-world | grep "Hello from Docker!" || (echo "ERROR: Docker installation failed, exiting." && exit -1)
    printf "%s: %s\n" "$(date +"%T.%N")" "Configured docker storage to use mountpoint"
}

disable_swap() {
    # Turn swap off and comment out swap line in /etc/fstab
    sudo swapoff -a
    if [ $? -eq 0 ]; then   
        printf "%s: %s\n" "$(date +"%T.%N")" "Turned off swap"
    else
        echo "***Error: Failed to turn off swap, which is necessary for Kubernetes"
        exit -1
    fi
    sudo sed -i.bak 's/UUID=.*swap/# &/' /etc/fstab
}

setup_secondary() {
    coproc nc { nc -l $1 $SECONDARY_PORT; }
    while true; do
        printf "%s: %s\n" "$(date +"%T.%N")" "Waiting for command to join kubernetes cluster, nc pid is $nc_PID"
        read -r -u${nc[0]} cmd
        case $cmd in
            *"kube"*)
                MY_CMD=$cmd
                break 
                ;;
            *)
	    	printf "%s: %s\n" "$(date +"%T.%N")" "Read: $cmd"
                ;;
        esac
	if [ -z "$nc_PID" ]
	then
	    printf "%s: %s\n" "$(date +"%T.%N")" "Restarting listener via netcat..."
	    coproc nc { nc -l $1 $SECONDARY_PORT; }
	fi
    done

    # Remove forward slash, since original command was on two lines
    MY_CMD=$(echo sudo $MY_CMD | sed 's/\\//')

    printf "%s: %s\n" "$(date +"%T.%N")" "Command to execute is: $MY_CMD"

    # run command to join kubernetes cluster
    eval $MY_CMD
    printf "%s: %s\n" "$(date +"%T.%N")" "Done!"
}

setup_primary() {
    # initialize k8 primary node
    printf "%s: %s\n" "$(date +"%T.%N")" "Starting Kubernetes... (this can take several minutes)... "
    sudo kubeadm init --apiserver-advertise-address=$1 --pod-network-cidr=10.244.0.0/16 > $INSTALL_DIR/k8s_install.log 2>&1
    if [ $? -eq 0 ]; then
        printf "%s: %s\n" "$(date +"%T.%N")" "Done! Output in $INSTALL_DIR/k8s_install.log"
    else
        echo ""
        echo "***Error: Error when running kubeadm init command. Check log found in $INSTALL_DIR/k8s_install.log."
        exit 1
    fi

    # Set up kubectl for all users
    for FILE in /users/*; do
        CURRENT_USER=${FILE##*/}
        sudo mkdir /users/$CURRENT_USER/.kube
        sudo cp /etc/kubernetes/admin.conf /users/$CURRENT_USER/.kube/config
        sudo chown -R $CURRENT_USER:$PROFILE_GROUP /users/$CURRENT_USER/.kube
	printf "%s: %s\n" "$(date +"%T.%N")" "set /users/$CURRENT_USER/.kube to $CURRENT_USER:$PROFILE_GROUP!"
	ls -lah /users/$CURRENT_USER/.kube
    done
    printf "%s: %s\n" "$(date +"%T.%N")" "Done!"
}

apply_flannel() {
    kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml >> $INSTALL_DIR/flannel_install.log 2>&1
    if [ $? -ne 0 ]; then
       echo "***Error: Error when installing flannel. Logs in $INSTALL_DIR/flannel_install.log"
       exit 1
    fi
    printf "%s: %s\n" "$(date +"%T.%N")" "Applied Flannel networking"

    # wait for flannel pods to be in ready state
    printf "%s: %s\n" "$(date +"%T.%N")" "Waiting for flannel pods to have status of 'Running': "
    NUM_PODS=$(kubectl get pods -n kube-flannel | wc -l)
    NUM_RUNNING=$(kubectl get pods -n kube-flannel | grep " Running" | wc -l)
    NUM_RUNNING=$((NUM_PODS-NUM_RUNNING))
    while [ "$NUM_RUNNING" -ne 0 ]
    do
        sleep 1
        printf "."
        NUM_RUNNING=$(kubectl get pods -n kube-flannel | grep " Running" | wc -l)
        NUM_RUNNING=$((NUM_PODS-NUM_RUNNING))
    done
    printf "%s: %s\n" "$(date +"%T.%N")" "Flannel pods running!"
    
    # wait for kube-system pods to be in ready state
    printf "%s: %s\n" "$(date +"%T.%N")" "Waiting for all system pods to have status of 'Running': "
    NUM_PODS=$(kubectl get pods -n kube-system | wc -l)
    NUM_RUNNING=$(kubectl get pods -n kube-system | grep " Running" | wc -l)
    NUM_RUNNING=$((NUM_PODS-NUM_RUNNING))
    while [ "$NUM_RUNNING" -ne 0 ]
    do
        sleep 1
        printf "."
        NUM_RUNNING=$(kubectl get pods -n kube-system | grep " Running" | wc -l)
        NUM_RUNNING=$((NUM_PODS-NUM_RUNNING))
    done
    printf "%s: %s\n" "$(date +"%T.%N")" "Kubernetes system pods running!"
}

add_cluster_nodes() {
    REMOTE_CMD=$(tail -n 2 $INSTALL_DIR/k8s_install.log)
    printf "%s: %s\n" "$(date +"%T.%N")" "Remote command is: $REMOTE_CMD"

    NUM_REGISTERED=$(kubectl get nodes | wc -l)
    NUM_REGISTERED=$(($1-NUM_REGISTERED+1))
    counter=0
    while [ "$NUM_REGISTERED" -ne 0 ]
    do 
	      sleep 2
        printf "%s: %s\n" "$(date +"%T.%N")" "Registering nodes, attempt #$counter, registered=$NUM_REGISTERED"
        for (( i=2; i<=$1; i++ ))
        do
            SECONDARY_IP=$BASE_IP$i
            echo $SECONDARY_IP
            exec 3<>/dev/tcp/$SECONDARY_IP/$SECONDARY_PORT
            echo $REMOTE_CMD 1>&3
            exec 3<&-
        done
	      counter=$((counter+1))
        NUM_REGISTERED=$(kubectl get nodes | wc -l)
        NUM_REGISTERED=$(($1-NUM_REGISTERED+1)) 
    done

    printf "%s: %s\n" "$(date +"%T.%N")" "Waiting for all nodes to have status of 'Ready': "
    NUM_READY=$(kubectl get nodes | grep " Ready" | wc -l)
    NUM_READY=$(($1-NUM_READY))
    while [ "$NUM_READY" -ne 0 ]
    do
        sleep 1
        printf "."
        NUM_READY=$(kubectl get nodes | grep " Ready" | wc -l)
        NUM_READY=$(($1-NUM_READY))
    done
    printf "%s: %s\n" "$(date +"%T.%N")" "Done!"
}

apply_multus() {
    # Checkout multus directory. Always use same commit for stable environment
    cd $INSTALL_DIR
    git clone https://github.com/k8snetworkplumbingwg/multus-cni.git
    cd multus-cni
    git checkout $MULTUS_COMMIT
    
    # Enable namespace isolation
    sudo sed -i '163 i \            - "-namespace-isolation=true"' deployments/multus-daemonset-thick.yml
    
    # Install multus
    cat ./deployments/multus-daemonset-thick.yml | kubectl apply -f - >> $INSTALL_DIR/multus_install.log 2>&1
    if [ $? -ne 0 ]; then
       echo "***Error: Error when installing multus. Logs in $INSTALL_DIR/multus_install.log"
       exit 1
    fi
    printf "%s: %s\n" "$(date +"%T.%N")" "Applied multus CNI plugin"

    # wait for multus pods to be in ready state
    printf "%s: %s\n" "$(date +"%T.%N")" "Waiting for flannel pods to have status of 'Running': "
    NUM_PODS=$(kubectl get pods -n kube-system | grep multus | wc -l)
    NUM_RUNNING=$(kubectl get pods -n kube-system | grep multus | grep " Running" | wc -l)
    NUM_RUNNING=$((NUM_PODS-NUM_RUNNING))
    while [ "$NUM_RUNNING" -ne 0 ]
    do
        sleep 1
        printf "."
        NUM_RUNNING=$(kubectl get pods -n kube-system | grep multus | grep " Running" | wc -l)
        NUM_RUNNING=$((NUM_PODS-NUM_RUNNING))
    done
    printf "%s: %s\n" "$(date +"%T.%N")" "Multus pods running!"
}


# Start by recording the arguments
printf "%s: args=(" "$(date +"%T.%N")"
for var in "$@"
do
    printf "'%s' " "$var"
done
printf ")\n"

# Check the min number of arguments
if [ $# -lt $NUM_MIN_ARGS ]; then
    echo "***Error: Expected at least $NUM_MIN_ARGS arguments."
    echo "$USAGE"
    exit -1
fi

# Check to make sure the first argument is as expected
if [ $1 != $PRIMARY_ARG -a $1 != $SECONDARY_ARG ] ; then
    echo "***Error: First arg should be '$PRIMARY_ARG' or '$SECONDARY_ARG'"
    echo "$USAGE"
    exit -1
fi

# Kubernetes does not support swap, so we must disable it
disable_swap

# Use mountpoint (if it exists) to set up additional docker image storage
if test -d "/mydata"; then
    configure_docker_storage
fi

# All all users to the docker group

# Fix permissions of install dir, add group for all users to set permission of shared files correctly
sudo groupadd $PROFILE_GROUP
for FILE in /users/*; do
    CURRENT_USER=${FILE##*/}
    sudo gpasswd -a $CURRENT_USER $PROFILE_GROUP
    sudo gpasswd -a $CURRENT_USER docker
done
sudo chown -R $USER:$PROFILE_GROUP $INSTALL_DIR
sudo chmod -R g+rw $INSTALL_DIR

# Ensure kernel modules are loaded
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Set system configurations for Kubernetes networking
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
# At this point, a secondary node is fully configured until it is time for the node to join the cluster.
if [ $1 == $SECONDARY_ARG ] ; then

    # Exit early if we don't need to start Kubernetes
    if [ "$3" == "False" ]; then
        printf "%s: %s\n" "$(date +"%T.%N")" "Start Kubernetes is $3, done!"
        exit 0
    fi
    
    # Use second argument (node IP) to replace filler in kubeadm configuration
    sudo sed -i.bak "s/REPLACE_ME_WITH_IP/$2/g" /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

    setup_secondary $2
    exit 0
fi

# Check the min number of arguments
if [ $# -ne $NUM_PRIMARY_ARGS ]; then
    echo "***Error: Expected at least $NUM_PRIMARY_ARGS arguments."
    echo "$USAGE"
    exit -1
fi

# Exit early if we don't need to start Kubernetes
if [ "$4" = "False" ]; then
    printf "%s: %s\n" "$(date +"%T.%N")" "Start Kubernetes is $4, done!"
    exit 0
fi

# Use second argument (node IP) to replace filler in kubeadm configuration
sudo sed -i.bak "s/REPLACE_ME_WITH_IP/$2/g" /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

# Finish setting up the primary node
# Argument is node_ip
setup_primary $2

# Apply flannel networking
apply_flannel

# Install multus CNI plugin
apply_multus

# Coordinate master to add nodes to the kubernetes cluster
# Argument is number of nodes
add_cluster_nodes $3

printf "%s: %s\n" "$(date +"%T.%N")" "Profile setup completed!"
