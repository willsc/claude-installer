Here's the script. It runs an A/B test comparing your current rx-usecs value against a candidate (default 0) and measures:

Interrupt rate (via /proc/interrupts)
CPU usage & softirq overhead (via mpstat)
Latency — min/avg/max/jitter (via ping, if you provide a target)
Throughput (via iperf3, optional)

It then gives a side-by-side comparison and a recommendation.
Usage examples:
bash# Basic latency test
sudo ./rx_usecs_benchmark.sh -i eth0 -t 10.0.0.1

# Longer test with throughput (needs iperf3 server on target)
sudo ./rx_usecs_benchmark.sh -i eth0 -t 10.0.0.1 -d 20 -T

# Test an intermediate value instead of 0
sudo ./rx_usecs_benchmark.sh -i eth0 -t 10.0.0.1 -c 5
Key notes:

Requires ethtool and sysstat (mpstat). Optional: iperf3 for throughput.
It automatically restores your original settings when done (including adaptive coalescing if it was on).
Run it during a representative workload for the most meaningful results — idle-system numbers won't tell you much.

