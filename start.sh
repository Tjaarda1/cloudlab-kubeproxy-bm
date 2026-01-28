#!/bin/bash

set -x
BASE_IP="10.10.1."
SECONDARY_PORT=3000
INSTALL_DIR=/home/eebpf
PROFILE_GROUP="eebpf"
MULTUS_COMMIT="77e0150"

PRIMARY_ARG="primary"
SECONDARY_ARG="secondary"
USAGE=$'Usage:
\t./start.sh secondary <node_ip> <start_kubernetes> <cni_plugin> <kube_proxy_mode> <socket_lb>
\t./start.sh primary   <node_ip> <num_nodes> <start_kubernetes> <cni_plugin> <kube_proxy_mode> <socket_lb>'


printf "%s: args=(" "$(date +"%T.%N")"
for var in "$@"; do
    printf "'%s' " "$var"
done
printf ")\n"

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
    coproc nc { nc -l $NODE_IP $SECONDARY_PORT; }
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
	    coproc nc { nc -l $NODE_IP $SECONDARY_PORT; }
	fi
    done


    echo "KUBELET_EXTRA_ARGS=--node-ip=$NODE_IP" | sudo tee /etc/default/kubelet

    # Remove forward slash, since original command was on two lines
    MY_CMD=$(echo sudo $MY_CMD | sed 's/\\//')
    printf "%s: %s\n" "$(date +"%T.%N")" "Command to execute is: $MY_CMD"

    # run command to join kubernetes cluster
    eval $MY_CMD
    printf "%s: %s\n" "$(date +"%T.%N")" "Done!"
}
setup_primary() {
    case "$CNI_PLUGIN" in
        "flannel")
            POD_CIDR="10.244.0.0/16"
            ;;
        "calico")
            POD_CIDR="192.168.0.0/16"
            ;;
        "cilium")
            POD_CIDR="10.0.0.0/8"
            ;;
        *)
            # Fallback default 
            POD_CIDR="10.244.0.0/16"
            ;;
    esac
   # Use second argument (node IP) to replace filler in kubeadm configuration
    sudo sed -i.bak "s/REPLACE_ME_WITH_IP/$NODE_IP/g" /etc/kubeadm/init-config.yaml
    sudo sed -i.bak "s|REPLACE_ME_WITH_CIDR|$POD_CIDR|g" /etc/kubeadm/init-config.yaml

    if [ "$KUBE_PROXY_MODE" != "ebpf" ]; then
        cat <<EOF | sudo tee -a /etc/kubeadm/init-config.yaml
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: "$KUBE_PROXY_MODE"
EOF
    fi
    
    # initialize k8 primary node
    printf "%s: %s\n" "$(date +"%T.%N")" "Starting Kubernetes... (this can take several minutes)... "
    if [[ "$KUBE_PROXY_MODE" == "skip" || "$KUBE_PROXY_MODE" == "ebpf" ]]; then
        sudo kubeadm init  --skip-phases=addon/kube-proxy --config /etc/kubeadm/init-config.yaml > $INSTALL_DIR/k8s_install.log 2>&1
        
    else
        sudo kubeadm init  --config /etc/kubeadm/init-config.yaml > $INSTALL_DIR/k8s_install.log 2>&1
    fi
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

apply_cni() {
    printf "%s: %s\n" "$(date +"%T.%N")" "Applying CNI Plugin: $CNI_PLUGIN"
    
    case "$CNI_PLUGIN" in 
        "flannel")
            kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml >> $INSTALL_DIR/flannel_install.log 2>&1
            if [ $? -ne 0 ]; then
               echo "***Error: Error when installing flannel. Logs in $INSTALL_DIR/flannel_install.log"
               exit 1
            fi
            printf "%s: %s\n" "$(date +"%T.%N")" "Applied Flannel networking manifests"

            # Wait for flannel pods to be in ready state
            printf "%s: %s\n" "$(date +"%T.%N")" "Waiting for flannel pods to have status of 'Running': "
            # Give the API server a moment to register the new pods
            kubectl wait --namespace kube-flannel --for=condition=Ready pods --all --timeout=60s
            printf "\n%s: %s\n" "$(date +"%T.%N")" "Flannel pods running!"
            ;;
            
        "calico")
            # Only apply here if not in eBPF mode (if eBPF, usually handled via specialized config or different CNI usage)
            printf "%s: %s\n" "$(date +"%T.%N")" "Installing Tigera Operator..."
            kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.2/manifests/tigera-operator.yaml >> $INSTALL_DIR/calico_install.log 2>&1
            printf "%s: %s\n" "$(date +"%T.%N")" "Waiting for Tigera Operator to be available..."
            kubectl wait --for=condition=Ready --timeout=90s pod -l k8s-app=tigera-operator -n tigera-operator >> $INSTALL_DIR/calico_install.log 2>&1
            # TODO: this is not enough, sometimes the pod is running but still needs some time to setup, and it may fail to take the custom resources. fix.
            sleep 20
            if [ "$KUBE_PROXY_MODE" != "ebpf" ]; then
                


                printf "%s: %s\n" "$(date +"%T.%N")" "Applying Calico Custom Resources..."
                kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.2/manifests/custom-resources.yaml >> $INSTALL_DIR/calico_install.log 2>&1
                
                if [ $? -ne 0 ]; then
                    echo "***Error: Error when installing Calico resources. Logs in $INSTALL_DIR/calico_install.log"
                    exit 1
                fi
            else
                kubectl patch deployment -n tigera-operator tigera-operator -p '{"spec":{"template":{"spec":{"dnsConfig":{"nameservers":["169.254.169.253"]}}}}}'                
                kubectl apply -f - <<EOF
kind: ConfigMap
apiVersion: v1
metadata:
  name: kubernetes-services-endpoint
  namespace: tigera-operator
data:
  KUBERNETES_SERVICE_HOST: "$NODE_IP"
  KUBERNETES_SERVICE_PORT: "6443"
EOF
                # This section includes base Calico installation configuration.
# For more information, see: https://docs.tigera.io/calico/latest/reference/installation/api#operator.tigera.io/v1.Installation
                cat <<EOF > custom-resources.yaml
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  # Configures Calico networking.
  calicoNetwork:
    linuxDataplane: BPF
    ipPools:
      - name: default-ipv4-ippool
        blockSize: 26
        cidr: ${POD_CIDR}
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()

---
# This section configures the Calico API server.
# For more information, see: https://docs.tigera.io/calico/latest/reference/installation/api#operator.tigera.io/v1.APIServer
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}

---
# Configures the Calico Goldmane flow aggregator.
apiVersion: operator.tigera.io/v1
kind: Goldmane
metadata:
  name: default

---
# Configures the Calico Whisker observability UI.
apiVersion: operator.tigera.io/v1
kind: Whisker
metadata:
  name: default
EOF
                kubectl create -f custom-resources.yaml >> $INSTALL_DIR/calico_install.log 2>&1
                
                if [ $? -ne 0 ]; then
                    echo "***Error: Error when installing Calico resources. Logs in $INSTALL_DIR/calico_install.log"
                    exit 1
                fi
            fi
            ;;
            
        "cilium")
            # Note: If KUBE_PROXY_MODE is ebpf, Cilium is likely installed during setup_primary.
            # This block handles the standard kube-proxy mode.
            if [ "$KUBE_PROXY_MODE" != "ebpf" ]; then
                sudo helm repo add cilium https://helm.cilium.io/
                sudo helm repo update
                sudo helm install cilium cilium/cilium --version 1.18.4 --set debug.enabled=true --namespace kube-system >> $INSTALL_DIR/cilium_install.log 2>&1
                
                if [ $? -ne 0 ]; then
                    echo "***Error: Error when installing Cilium. Logs in $INSTALL_DIR/cilium_install.log"
                    exit 1
                fi
            else 
                SOCKET_LB_FLAG="--set socketLB.hostNamespaceOnly=true"
                if [ "$SOCKET_LB" == "True" ] || [ "$SOCKET_LB" == "true" ]; then
                    SOCKET_LB_FLAG="--set socketLB.hostNamespaceOnly=false"
                fi
                sudo helm repo add cilium https://helm.cilium.io/
                API_SERVER_IP=$NODE_IP
                API_SERVER_PORT=6443
                sudo helm install cilium cilium/cilium --version 1.18.4 \
                    --namespace kube-system \
                    --set kubeProxyReplacement=true \
                    --set k8sServiceHost=${API_SERVER_IP} \
                    --set k8sServicePort=${API_SERVER_PORT} \
                    --set debug.enabled=true \
                    $SOCKET_LB_FLAG
            fi
            ;;
            "cilium-min")
            
                SOCKET_LB_FLAG="--set socketLB.hostNamespaceOnly=true"
                if [ "$SOCKET_LB" == "True" ] || [ "$SOCKET_LB" == "true" ]; then
                    SOCKET_LB_FLAG="--set socketLB.hostNamespaceOnly=false"
                fi
                sudo helm repo add cilium https://helm.cilium.io/
                API_SERVER_IP=$NODE_IP
                API_SERVER_PORT=6443
                sudo helm install cilium cilium/cilium --version 1.18.4 \
                    --namespace kube-system \
                    --set kubeProxyReplacement=true \
                    --set k8sServiceHost=${API_SERVER_IP} \
                    --set k8sServicePort=${API_SERVER_PORT} \
                    --set image.repository=alexdecb/cilium \
                    --set image.tag=lbtest \  
                    $SOCKET_LB_FLAG
            fi
            ;;
        *)
            printf "Skipping CNI installation" 
            ;;
    esac

    
    printf "\n%s: %s\n" "$(date +"%T.%N")" "All Kubernetes system pods are running!"
}

add_cluster_nodes() {
    REMOTE_CMD=$(kubeadm token create --print-join-command)
    printf "%s: %s\n" "$(date +"%T.%N")" "Remote command is: $REMOTE_CMD"

    NUM_REGISTERED=$(kubectl get nodes | wc -l)
    NUM_REGISTERED=$(($NODE_COUNT-NUM_REGISTERED+1))
    counter=0
    while [ "$NUM_REGISTERED" -ne 0 ]
    do 
	      sleep 2
        printf "%s: %s\n" "$(date +"%T.%N")" "Registering nodes, attempt #$counter, registered=$NUM_REGISTERED"
        for (( i=2; i<=$NODE_COUNT; i++ ))
        do
            SECONDARY_IP=$BASE_IP$i
            echo $SECONDARY_IP
            exec 3<>/dev/tcp/$SECONDARY_IP/$SECONDARY_PORT
            echo $REMOTE_CMD 1>&3
            exec 3<&-
        done
	      counter=$((counter+1))
        NUM_REGISTERED=$(kubectl get nodes | wc -l)
        NUM_REGISTERED=$(($NODE_COUNT-NUM_REGISTERED+1)) 
    done

    printf "%s: %s\n" "$(date +"%T.%N")" "Waiting for all nodes to have status of 'Ready': "
    NUM_READY=$(kubectl get nodes | grep " Ready" | wc -l)
    NUM_READY=$(($NODE_COUNT-NUM_READY))
    while [ "$NUM_READY" -ne 0 ]
    do
        sleep 1
        printf "."
        NUM_READY=$(kubectl get nodes | grep " Ready" | wc -l)
        NUM_READY=$(($NODE_COUNT-NUM_READY))
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


# 1. Capture the Role and IP (Common to both)
ROLE=$1
NODE_IP=$2

# 2. Parse remaining arguments based on Role
if [[ "$ROLE" == "primary" ]]; then
    # Primary args: IP, NodeCount, StartK8s, CNI, Proxy, SocketLB
    NODE_COUNT=$3
    START_K8S=$4
    CNI_PLUGIN=$5
    KUBE_PROXY_MODE=$6
    SOCKET_LB=$7
else
    # Secondary args: IP, StartK8s, CNI, Proxy, SocketLB (NodeCount is skipped)
    START_K8S=$3
    CNI_PLUGIN=$4
    KUBE_PROXY_MODE=$5
    SOCKET_LB=$6
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
    sudo gpasswd -a $CURRENT_USER docker/etc/kubeadm/config.yaml
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

if [ "$KUBE_PROXY_MODE" == "ipvs" ]; then
    sudo modprobe ip_vs 
    sudo modprobe ip_vs_rr
    sudo modprobe ip_vs_wrr 
    sudo modprobe ip_vs_sh
    sudo modprobe nf_conntrack  
    sudo apt install ipset ipvsadm -y
fi

# TODO: Compatibility check for iptables vs nftables in image. Probably should create different base images for each. https://manpages.debian.org/testing/nftables/nft.8.en.html
if [ "$KUBE_PROXY_MODE" == "nftables" ]; then
    sudo modprobe nf_tables
fi

sudo sysctl --system
# At this point, a secondary node is fully configured until it is time for the node to join the cluster.
if [ "$ROLE" == "$SECONDARY_ARG" ] ; then

    # Exit early if we don't need to start Kubernetes
    if [ "$START_K8S" == "False" ]; then
        printf "%s: %s\n" "$(date +"%T.%N")" "Start Kubernetes is $START_K8S, done!"
        exit 0
    fi
    
    # Use second argument (node IP) to replace filler in kubeadm configuration
   # sudo sed -i.bak "s/REPLACE_ME_WITH_IP/$NODE_IP/g" /etc/kubeadm/config.yaml

    setup_secondary
    exit 0
fi



# Exit early if we don't need to start Kubernetes
if [ "$START_K8S" = "False" ]; then
    printf "%s: %s\n" "$(date +"%T.%N")" "Start Kubernetes is $START_K8S, done!"
    exit 0
fi



# Finish setting up the primary node
# Argument is node_ip
setup_primary 

# Apply flannel networking
apply_cni

# Install multus CNI plugin
#apply_multus

# Coordinate master to add nodes to the kubernetes cluster
# Argument is number of nodes
add_cluster_nodes 

printf "%s: %s\n" "$(date +"%T.%N")" "Profile setup completed!"
