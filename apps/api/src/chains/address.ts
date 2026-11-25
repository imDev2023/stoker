import { checksum } from "@launchpad/evm";

const EVM_ADDRESS = /^0x[0-9a-fA-F]{40}$/;

/**
 * An address as the database holds it (#252): an EVM address in its checksummed form, whatever case it came in (a
 * wallet's `eth_accounts` answers lower case, an explorer may answer upper), and a Solana address as it is, base58 being
 * case-sensitive. Every lookup by a caller's address goes through here.
 */
export const canonicalAddress = (address: string) => (EVM_ADDRESS.test(address) ? checksum(address.toLowerCase()) : address);
