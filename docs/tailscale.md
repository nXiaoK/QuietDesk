# Connecting QuietDesk over Tailscale

Each copy of QuietDesk on macOS or Windows can join your tailnet as its own device. Both computers only need QuietDesk installed. The feature is opt-in. Regular LAN connections work without a Tailscale account.

1. On both computers, open Tailscale in QuietDesk settings and choose **登录 Tailscale**. Complete the official sign-in in the browser and return to QuietDesk. If your tailnet requires device approval, wait for your administrator to approve each QuietDesk node.
2. On the host, start QuietDesk sharing. Check that the Tailscale settings show an assigned IPv4 address and the published sharing port. Share this address, port and the QuietDesk pairing code with the controller.
3. On the controller, enter the host’s address as `tailscale:100.x.x.x`, replacing the example with its actual address. On macOS you can also select the built-in Tailscale option and enter just the IP. Use the host’s QuietDesk port (default `5908`) and pairing code. Your tailnet policy must allow TCP on this port for the session and UDP for datagram media.

Tailscale handles the underlying peer-to-peer or relay path for the whole session. A blocked peer-to-peer path can use DERP, which can limit video throughput. QuietDesk’s TCP/UDP indicators describe the application transport. Even UDP video can travel through a Tailscale relay. [Tailscale connection types](https://tailscale.com/docs/reference/connection-types)

If the target cannot be found, check that both QuietDesk nodes have joined the intended tailnet and that its access policy permits the connection. Use the address displayed by QuietDesk. A separately installed system Tailscale client has its own node identity and address. If authentication fails after connecting, check the QuietDesk pairing code on the sharing computer.

Stopping sharing closes the published QuietDesk port. Quitting QuietDesk stops its embedded node. Enabled installations restore the node's private state from the current user's application data on launch. Use the sign-out action to leave the account. Tailnet membership and the QuietDesk pairing credential are separate.
