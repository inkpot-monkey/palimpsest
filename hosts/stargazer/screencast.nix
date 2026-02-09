{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    gnome-network-displays
    intel-media-driver # Critical for Iris Xe hardware encoding
    libva-utils # For checking driver status
  ];

  # Enable OpenGL/VAAPI support at the OS level
  hardware.graphics = {
    # Note: In older NixOS versions, this might be 'hardware.opengl'
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      intel-vaapi-driver # Fallback
    ];
  };

  # 1. Open Firewall for Miracast (GNOME Network Displays)
  networking.firewall = {
    enable = true;
    # 1. Miracast Control Ports (TCP/UDP)
    allowedTCPPorts = [
      7236
      7250
    ];
    # 2. DHCP (67, 68) - ESSENTIAL for "Reason 67" fix
    # 3. Discovery (5353) and Control (7236, 7250)
    allowedUDPPorts = [
      5353
      7236
      7250
      67
      68
    ];
    # 4. Video Stream (Random High Ports)
    allowedUDPPortRanges = [
      {
        from = 32768;
        to = 60999;
      }
    ];
    # 5. Trust the dynamic P2P interfaces
    trustedInterfaces = [
      "wlp170s0"
      "p2p-wlp170s0-0"
      "p2p-wlp170s0-1"
      "p2p-wlp170s0-2"
      "p2p-wlp170s0-3"
      "p2p-wlp170s0-4"
    ];
    # 6. Allow asymmetrical routing (required for P2P)
    checkReversePath = false;
  };

  # 2. Enable XDG Portals (Required for the "Screen Recording" handshake)
  xdg.portal = {
    enable = true;
    # Ensure you have the GNOME portal backend, even if not on full GNOME
    extraPortals = with pkgs; [
      xdg-desktop-portal-gnome
    ];
  };

  # 3. Ensure NetworkManager is managing Wi-Fi (Miracast requires this backend)
  networking.networkmanager.wifi.backend = "wpa_supplicant";
}
