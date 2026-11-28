# Connecting QuietDesk over Tailscale

Each copy of QuietDesk on macOS or Windows can join your tailnet as its own device. Both computers only need QuietDesk installed. The feature is opt-in. Regular LAN connections work without a Tailscale account.

1. On both computers, open Tailscale in QuietDesk settings and choose **登录 Tailscale**. Complete sign-in in the browser and return to QuietDesk. If your tailnet requires device approval, wait for your administrator to approve each QuietDesk node.
2. On the host, start QuietDesk sharing. Check that the Tailscale settings show an assigned IPv4 address and the published sharing port. Share this address, port and the QuietDesk pairing code with the controller.
3. On the controller, enter the host’s address as `tailscale:100.x.x.x`, replacing the example with its actual address. On macOS you can also select the built-in Tailscale option and enter just the IP. Use the host’s QuietDesk port (default `5908`) and pairing code. Your tailnet policy must allow TCP on this port for the session and UDP for datagram media.

## Connection path

During a Tailscale connection, QuietDesk settings show **P2P 打洞直连** when Tailscale reports a direct link and **DERP 中继转发** when it reports relay forwarding. When available, the DERP region code appears in the label, for example **DERP 中继 (hkg)**. The label appears once the helper can identify a peer path. DERP can limit video throughput. The separate TCP/UDP indicators describe QuietDesk’s application transport. Either transport can traverse DERP. [Tailscale connection types](https://tailscale.com/docs/reference/connection-types)

The embedded node saves its local WireGuard UDP port in `wg-port` under its Tailscale state directory and reuses it on restart. QuietDesk connections still use the sharing port displayed by the host.

## Custom control server on macOS

For a self-hosted Headscale network, open the Tailscale settings on macOS and enter the server’s HTTPS URL in **控制服务**. The address can include a port and must be free of credentials, query parameters, and fragments. Click **保存控制服务**, then sign in through the browser when prompted. Changing the server restarts the embedded node. QuietDesk keeps the official and custom node identities in separate local state directories and reuses the same WireGuard UDP port across them. Enroll the two QuietDesk devices in the same tailnet and allow the host’s sharing port in the access policy.

To use a DERP server in mainland China, configure the DERP map on your Headscale server. The embedded nodes receive that map from the control server, and the connection path label shows the region when Tailscale reports DERP. Click **恢复官方默认** to return to the official Tailscale control server.

## Troubleshooting

If the target cannot be found, check that both QuietDesk nodes have joined the intended tailnet and that its access policy permits the connection. Use the address displayed by QuietDesk. A separately installed system Tailscale client has its own node identity and address. If authentication fails after connecting, check the QuietDesk pairing code on the sharing computer.

Stopping sharing closes the published QuietDesk port. Quitting QuietDesk stops its embedded node. Enabled installations restore the node's private state from the current user's application data on launch. Use the sign-out action to leave the account. Tailnet membership and the QuietDesk pairing credential are separate.
