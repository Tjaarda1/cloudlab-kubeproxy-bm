
"""
CloudLab profile to set up a Kubernetes cluster with flannel CNI and multus CNI plugin installed. Each node runs Ubuntu24.04.

Instructions:
Create the experiment in CloudLab. Wait until the start script completes (can see status in the CloudLab experiment page). Interact with the cluster
using kubectl on node1 (the control-plane node). If something goes wrong, check the logs found in /home/eebpf.
"""

import time

# Import the Portal object.
import geni.portal as portal
# Import the ProtoGENI library.
import geni.rspec.pg as rspec

BASE_IP = "10.10.1"
BANDWIDTH = 10000000
IMAGE = ' urn:publicid:IDN+apt.emulab.net+image+meshbench-PG0:kubeproxy-bm:2'

# Set up parameters
pc = portal.Context()
pc.defineParameter("nodeCount", 
                   "Number of nodes in the experiment.",
                   portal.ParameterType.INTEGER, 
                   1)
pc.defineParameter("nodeType", 
                   "Node Hardware Type",
                   portal.ParameterType.NODETYPE, 
                   "r320",
                   longDescription="A specific hardware type to use for all nodes. This profile has primarily been tested with r320 nodes.")
pc.defineParameter("startKubernetes",
                   "Create Kubernetes cluster",
                   portal.ParameterType.BOOLEAN,
                   True,
                   longDescription="Create a Kubernetes cluster using the parameters. If false, kubeadm init won't be called.")
# --- CNI Parameter ---
pc.defineParameter("cni",
                   "CNI Plugin",
                   portal.ParameterType.STRING,
                   "Flannel",
                   legalValues=["Flannel", "Calico", "Cilium"],
                   longDescription="Choose which CNI Plugin will be used.")

# --- KubeProxy Parameter ---
pc.defineParameter("kubeproxy",
                   "KubeProxy Mode",
                   portal.ParameterType.STRING,
                   "iptables",
                   legalValues=["iptables", "ipvs", "nftables", "ebpf"],
                   longDescription="Choose kubeproxy mode. Note: eBPF mode is only supported for Calico and Cilium.")
# Below option copy/pasted directly from small-lan experiment on CloudLab
# Optional ephemeral blockstore
pc.defineParameter("tempFileSystemSize", 
                   "Temporary Filesystem Size",
                   portal.ParameterType.INTEGER, 
                   0,
                   advanced=True,
                   longDescription="The size in GB of a temporary file system to mount on each of your " +
                   "nodes. Temporary means that they are deleted when your experiment is terminated. " +
                   "The images provided by the system have small root partitions, so use this option " +
                   "if you expect you will need more space to build your software packages or store " +
                   "temporary files. 0 GB indicates maximum size.")
params = pc.bindParameters()

if params.kubeproxy == "ebpf":
    if params.cni not in ["Calico", "Cilium"]:
        perr = portal.ParameterError(
            "KubeProxy in 'ebpf' mode is only supported when CNI is Calico or Cilium.",
            ['kubeproxy', 'cni'] 
        )
        pc.reportError(perr)



pc.verifyParameters()
request = pc.makeRequestRSpec()

def create_node(name, nodes, lan):
  # Create node
  node = request.RawPC(name)
  node.disk_image = IMAGE
  node.hardware_type = params.nodeType
  
  # Add interface
  iface = node.addInterface("if1")
  iface.addAddress(rspec.IPv4Address("{}.{}".format(BASE_IP, 1 + len(nodes)), "255.255.255.0"))
  lan.addInterface(iface)
  
  # Add extra storage space
  bs = node.Blockstore(name + "-bs", "/mydata")
  bs.size = str(params.tempFileSystemSize) + "GB"
  bs.placement = "any"
  # Add to node list
  nodes.append(node)

nodes = []
lan = request.LAN()
lan.bandwidth = BANDWIDTH

# Create nodes
# The start script relies on the idea that the primary node is 10.10.1.1, and subsequent nodes follow the
# pattern 10.10.1.2, 10.10.1.3, ...
for i in range(params.nodeCount):
    name = "node"+str(i+1)
    create_node(name, nodes, lan)

# Iterate over secondary nodes first
for i, node in enumerate(nodes[1:]):
    cmd = "bash /local/repository/start.sh secondary {}.{} {} {} {} > /home/eebpf/start.log 2>&1 &".format(
        BASE_IP, i + 2, params.startKubernetes, params.cni, params.kubeproxy
    )
    node.addService(rspec.Execute(shell="bash", command=cmd))

cmd_primary = "bash /local/repository/start.sh primary {}.1 {} {} {} {} > /home/eebpf/start.log 2>&1".format(
    BASE_IP, params.nodeCount, params.startKubernetes, params.cni, params.kubeproxy
)
nodes[0].addService(rspec.Execute(shell="bash", command=cmd_primary))

pc.printRequestRSpec()