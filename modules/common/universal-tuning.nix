{ config, lib, pkgs, ... }:

{
  nix = {
    settings = {
      max-jobs = "auto";
      cores = 0;
      auto-optimise-store = true;
      experimental-features = [ "nix-command" "flakes" ];
      http-connections = 50;
      connect-timeout = 5;
    };
    gc = {
      automatic = true;
      dates = "daily";
      options = lib.mkDefault "--delete-older-than 2d";
    };
    optimise = {
      automatic = true;
      dates = [ "daily" ];
    };
  };

  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 100;
    priority = 100;
  };

  environment.sessionVariables = {
    GLIBC_TUNABLES = "glibc.malloc.trim_threshold=131072:glibc.malloc.arena_max=4";
  };

  systemd.oomd = {
    enable = true;
    enableRootSlice = true;
    enableSystemSlice = true;
    enableUserSlices = true;
  };

  boot.kernelParams = [
    "cgroup_enable=cpuset"
    "cgroup_memory=1"
    "cgroup_enable=memory"
    "systemd.unified_cgroup_hierarchy=1"
    "log_buf_len=16M"
    "printk.devkmsg=on"
  ];

  boot.kernelModules = [ "tcp_bbr" ];

  boot.kernel.sysctl = lib.mapAttrs (_: lib.mkForce) {
    "vm.swappiness" = 180;
    "vm.page-cluster" = 0;
    "vm.vfs_cache_pressure" = 50;
    "vm.dirty_background_ratio" = 5;
    "vm.dirty_ratio" = 15;
    "vm.dirty_expire_centisecs" = 3000;
    "vm.dirty_writeback_centisecs" = 500;
    "vm.watermark_boost_factor" = 0;
    "vm.watermark_scale_factor" = 125;
    "vm.overcommit_memory" = 1;
    "vm.max_map_count" = 1048576;
    "vm.panic_on_oom" = 0;

    "fs.aio-max-nr" = 1048576;
    "fs.file-max" = 2097152;
    "fs.inotify.max_user_instances" = 8192;
    "fs.inotify.max_user_watches" = 1048576;
    "fs.inotify.max_queued_events" = 65536;

    "net.core.default_qdisc" = "fq";
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.core.netdev_max_backlog" = 16384;
    "net.core.netdev_budget" = 600;
    "net.core.netdev_budget_usecs" = 8000;
    "net.core.somaxconn" = 8192;
    "net.core.rmem_max" = 16777216;
    "net.core.wmem_max" = 16777216;
    "net.ipv4.tcp_rmem" = "4096 87380 16777216";
    "net.ipv4.tcp_wmem" = "4096 65536 16777216";
    "net.ipv4.tcp_fastopen" = 3;
    "net.ipv4.tcp_tw_reuse" = 1;
    "net.ipv4.ip_forward" = 1;
    "net.ipv6.conf.all.forwarding" = 1;

    "kernel.printk_ratelimit" = 0;
    "kernel.printk_ratelimit_burst" = 0;
    "kernel.dmesg_restrict" = 0;
    "kernel.panic" = 10;
    "kernel.panic_on_oops" = 1;
    "kernel.hung_task_panic" = 0;
  };

  systemd.tmpfiles.rules = [
    "w /sys/kernel/mm/lru_gen/enabled - - - - 0x0007"
    "w /sys/kernel/mm/lru_gen/min_ttl_ms - - - - 1000"
    "w /sys/kernel/mm/ksm/run - - - - 1"
    "w /sys/kernel/mm/ksm/pages_to_scan - - - - 1000"
    "w /sys/kernel/mm/ksm/sleep_millisecs - - - - 200"
    "w /sys/kernel/mm/transparent_hugepage/enabled - - - - madvise"
    "w /sys/kernel/mm/transparent_hugepage/defrag - - - - defer+madvise"
  ];

  services.udev.extraRules = ''
    ACTION=="add|change", SUBSYSTEM=="block", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none", ATTR{queue/rq_affinity}="2", ATTR{queue/nr_requests}="256", ATTR{queue/read_ahead_kb}="128"
    ACTION=="add|change", SUBSYSTEM=="block", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="mq-deadline", ATTR{queue/rq_affinity}="2", ATTR{queue/nr_requests}="256", ATTR{queue/read_ahead_kb}="1024"
  '';

  systemd.services.universal-hardware-parallel-tune = {
    description = "Optimisation parallèle agnostique CPU (P/E-Cores), Réseau (RPS/XPS/GRO) et I/O";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    path = with pkgs; [ coreutils findutils gawk ethtool util-linux ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      NPROC=$(nproc)
      CPU_MASK=$(printf '%x' $(( (1 << (NPROC > 32 ? 32 : NPROC)) - 1 )))

      for netdev in /sys/class/net/*; do
        (
          iface=$(basename "$netdev")
          [ "$iface" = "lo" ] && exit 0
          for rxq in "$netdev"/queues/rx-*; do
            [ -f "$rxq/rps_cpus" ] && echo "$CPU_MASK" > "$rxq/rps_cpus" 2>/dev/null || true
            [ -f "$rxq/rps_flow_cnt" ] && echo 4096 > "$rxq/rps_flow_cnt" 2>/dev/null || true
          done
          for txq in "$netdev"/queues/tx-*; do
            [ -f "$txq/xps_cpus" ] && echo "$CPU_MASK" > "$txq/xps_cpus" 2>/dev/null || true
          done
          ethtool -K "$iface" gro on gso on tso on 2>/dev/null || true
        ) &
      done

      for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        (
          if [ -f "$cpu_dir/cpufreq/scaling_governor" ]; then
            avail=$(cat "$cpu_dir/cpufreq/scaling_available_governors" 2>/dev/null || true)
            if echo "$avail" | grep -q "schedutil"; then
              echo "schedutil" > "$cpu_dir/cpufreq/scaling_governor" 2>/dev/null || true
            elif echo "$avail" | grep -q "performance"; then
              echo "performance" > "$cpu_dir/cpufreq/scaling_governor" 2>/dev/null || true
            fi
          fi
          if [ -f "$cpu_dir/cpufreq/energy_performance_preference" ]; then
            echo "balance_performance" > "$cpu_dir/cpufreq/energy_performance_preference" 2>/dev/null || true
          fi
        ) &
      done

      wait
    '';
  };

  systemd.settings.Manager = {
    DefaultCPUAccounting = true;
    DefaultIOAccounting = true;
    DefaultMemoryAccounting = true;
    DefaultTasksAccounting = true;
    RuntimeWatchdogSec = "30s";
    RebootWatchdogSec = "2m";
  };

  services.journald.extraConfig = lib.mkDefault ''
    Compress=yes
    RateLimitIntervalSec=0
    RateLimitBurst=0
    SyncIntervalSec=5m
    SystemMaxUse=100M
    RuntimeMaxUse=64M
    MaxRetentionSec=3d
    ForwardToSyslog=no
  '';

  environment.systemPackages = with pkgs; [
    ripgrep
    fd
    bottom
    jq
    yq-go
    ethtool
  ];
}
