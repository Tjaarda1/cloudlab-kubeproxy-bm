# Flexible Kubernetes Profile for CloudLab (Multi-CNI & Multi-Proxy)

> Status: Work in Progress 
> This profile is currently under active development. Features and configuration options are subject to change.

## Overview

This CloudLab profile creates a highly configurable Kubernetes cluster designed for network testing and benchmarking. It allows you to instantiate a cluster while selecting from various Container Network Interfaces (CNI), Kube Proxy modes, and hardware architectures.

### Key Features

1. Configurable CNI: Choose your preferred networking layer during setup (e.g., Flannel, Calico, Cilium).

2. Kube Proxy Modes: Select between standard iptables, high-performance ipvs, or bypass it entirely with eBPF-based replacement.

3. eBPF Support: Native support for modern eBPF dataplane acceleration.



## Acknowledgements

This work heavily references and builds upon the [cloudlab-k8s-flannel](https://github.com/hunhoffe/cloudlab-k8s-flannel) repository by [hunhoffe](https://github.com/hunhoffe).
