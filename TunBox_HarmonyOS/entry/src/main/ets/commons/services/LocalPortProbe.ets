import { socket } from '@kit.NetworkKit';

/** A listener using address reuse can pass a second bind. An accepting socket
 * is occupied regardless of whether the platform also lets us listen on it. */
export class LocalPortProbe {
  static async isFree(port: number): Promise<boolean> {
    const client = socket.constructTCPSocketInstance();
    try {
      await client.connect({ address: { address: '127.0.0.1', port: port, family: 1 }, timeout: 200 });
      return false;
    } catch (_e) {
      // Refusal alone does not prove availability: also check that we can bind.
    } finally {
      try { await client.close(); } catch (_e) {}
    }
    const server = socket.constructTCPSocketServerInstance();
    try {
      await server.listen({ address: '127.0.0.1', port: port, family: 1 });
      return true;
    } catch (_e) {
      return false;
    } finally {
      try { await server.close(); } catch (_e) {}
    }
  }
}
