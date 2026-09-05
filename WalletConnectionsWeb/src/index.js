import { createEVMClient } from "@metamask/connect-evm";
import { AddressType, BrowserSDK } from "@phantom/browser-sdk";
import { registerSlushWallet } from "@mysten/slush-wallet";
import { getWallets } from "@mysten/wallet-standard";
import { Transaction as SuiTransaction } from "@mysten/sui/transactions";
import { Transaction, VersionedTransaction } from "@solana/web3.js";

const MAX_COMMAND_BYTES = 256 * 1024;
const SESSION_LIFETIME_MS = 7 * 24 * 60 * 60 * 1000;
const SESSION_STORAGE_KEY = "locus.wallet.connectionMetadata.v1";
const CONNECTOR_NETWORKS = Object.freeze({
  metamask: Object.freeze({ "eip155:1": "0x1", "eip155:11155111": "0xaa36a7" }),
  phantom: Object.freeze({ "solana:mainnet-beta": "mainnet", "solana:devnet": "devnet" }),
  slush: Object.freeze({ "sui:mainnet": "sui:mainnet", "sui:testnet": "sui:testnet" }),
});
const CONNECTOR_METHODS = Object.freeze({
  metamask: new Set(["list_accounts", "switch_network", "send_transaction", "sign_in_with_ethereum"]),
  phantom: new Set(["list_accounts", "switch_network", "send_transaction", "sign_in_with_solana"]),
  slush: new Set(["list_accounts", "switch_network", "send_transaction"]),
});

let configuration = null;
let metamaskClient = null;
let metamaskProvider = null;
let phantomSDK = null;
let slushWallet = null;
let slushUnregister = null;
const liveSessions = new Map();

function setStatus(message) {
  const node = document.getElementById("status");
  if (node) node.textContent = message;
}

function fail(message) {
  throw new Error(String(message).slice(0, 512));
}

function assertObject(value, name) {
  if (!value || typeof value !== "object" || Array.isArray(value)) fail(`${name} is invalid.`);
  return value;
}

function assertString(value, name, maximum = 512) {
  if (typeof value !== "string" || value.length === 0 || value.length > maximum) {
    fail(`${name} is invalid.`);
  }
  return value;
}

function assertArray(value, name, maximum = 32) {
  if (!Array.isArray(value) || value.length > maximum) fail(`${name} is invalid.`);
  return value;
}

function uniqueStrings(value, name) {
  return [...new Set(assertArray(value, name).map((item) => assertString(item, name, 128)))];
}

function decodeBase64(value) {
  const input = assertString(value, "transaction", MAX_COMMAND_BYTES);
  let binary;
  try { binary = atob(input); } catch { fail("The transaction encoding is invalid."); }
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  if (bytes.length === 0 || bytes.length > MAX_COMMAND_BYTES) fail("The transaction is invalid.");
  return bytes;
}

function loadStoredSessions() {
  try {
    const value = JSON.parse(localStorage.getItem(SESSION_STORAGE_KEY) || "[]");
    return Array.isArray(value) ? value.filter(validStoredSession) : [];
  } catch {
    return [];
  }
}

function validStoredSession(session) {
  return session && typeof session === "object"
    && typeof session.connectionID === "string"
    && typeof session.connector === "string"
    && typeof session.expiresAt === "string"
    && Date.parse(session.expiresAt) > Date.now()
    && Array.isArray(session.accounts)
    && session.accounts.length > 0;
}

function persistPublicSession(session) {
  const sessions = loadStoredSessions().filter((item) => item.connectionID !== session.connectionID);
  sessions.push({
    connector: session.connector,
    connectionID: session.connectionID,
    peerName: session.peerName,
    peerURL: session.peerURL,
    peerID: session.peerID || null,
    networkIDs: session.networkIDs,
    approvedMethods: session.approvedMethods,
    accounts: session.accounts,
    expiresAt: session.expiresAt,
  });
  localStorage.setItem(SESSION_STORAGE_KEY, JSON.stringify(sessions.slice(-64)));
}

function removePublicSession(connectionID) {
  localStorage.setItem(
    SESSION_STORAGE_KEY,
    JSON.stringify(loadStoredSessions().filter((item) => item.connectionID !== connectionID)),
  );
  liveSessions.delete(connectionID);
}

function emit(connector, kind, connectionID, networkIDs) {
  const body = { connector, kind, connectionID };
  if (networkIDs) body.networkIDs = networkIDs;
  window.webkit?.messageHandlers?.locusConnectorEvents?.postMessage(body);
}

function newAccount(connector, chain, address, networkID, existingID, publicKeyBase64) {
  return {
    id: existingID || crypto.randomUUID().toLowerCase(),
    chain,
    address,
    ...(publicKeyBase64 ? { publicKeyBase64 } : {}),
    label: `${connector === "phantom" ? "Phantom-managed" : connector[0].toUpperCase() + connector.slice(1)} ${address.slice(0, 6)}…${address.slice(-4)}`,
    networkIDs: [networkID],
  };
}

function selectedNetwork(connector, request) {
  const requestedNetworks = uniqueStrings(request.requestedNetworkIDs, "requested networks");
  if (requestedNetworks.length !== 1 || !CONNECTOR_NETWORKS[connector]?.[requestedNetworks[0]]) {
    fail("Select exactly one supported connector network.");
  }
  return requestedNetworks[0];
}

function makeSession(connector, request, address, chain, peerName, peerURL, existing, publicKeyBase64) {
  const networkID = selectedNetwork(connector, request);
  const methods = uniqueStrings(request.requestedMethods, "requested methods")
    .filter((method) => CONNECTOR_METHODS[connector].has(method));
  if (methods.length === 0) fail("No supported connector methods were approved.");
  const account = newAccount(connector, chain, address, networkID,
    existing?.accounts?.[0]?.id, publicKeyBase64 || existing?.accounts?.[0]?.publicKeyBase64);
  return {
    connector,
    connectionID: assertString(request.requestID, "connection id", 64),
    peerName,
    peerURL,
    peerID: null,
    networkIDs: [networkID],
    approvedMethods: methods,
    accounts: [account],
    expiresAt: new Date(Date.now() + SESSION_LIFETIME_MS).toISOString(),
  };
}

async function getMetaMask() {
  if (!metamaskClient) {
    const supportedNetworks = {};
    for (const [networkID, chainID] of Object.entries(CONNECTOR_NETWORKS.metamask)) {
      const rpcURL = configuration.metamaskRPCURLs[networkID];
      if (typeof rpcURL === "string" && rpcURL.length > 0) {
        supportedNetworks[chainID] = assertString(rpcURL, "MetaMask provider URL", 2048);
      }
    }
    if (Object.keys(supportedNetworks).length === 0) fail("MetaMask provider configuration is unavailable.");
    metamaskClient = await createEVMClient({
      dapp: { name: "Locus", url: configuration.dappURL },
      api: { supportedNetworks },
      analytics: { enabled: false },
      skipAutoAnnounce: true,
    });
    metamaskProvider = metamaskClient.getProvider();
    metamaskProvider.on?.("accountsChanged", () => disconnectEventsFor("metamask"));
    metamaskProvider.on?.("chainChanged", (chainID) => {
      for (const session of sessionsFor("metamask")) {
        const networkID = Object.entries(CONNECTOR_NETWORKS.metamask)
          .find(([, value]) => value === String(chainID).toLowerCase())?.[0];
        emit("metamask", "network_changed", session.connectionID, networkID ? [networkID] : []);
      }
    });
    metamaskProvider.on?.("disconnect", () => disconnectEventsFor("metamask"));
  }
  return { client: metamaskClient, provider: metamaskProvider };
}

function getPhantom() {
  if (!phantomSDK) {
    const appId = assertString(configuration.phantomAppID, "Phantom app id", 256);
    const redirectUrl = assertString(configuration.phantomRedirectURL, "Phantom redirect URL", 2048);
    phantomSDK = new BrowserSDK({
      providers: ["phantom"],
      addressTypes: [AddressType.solana],
      appId,
      authOptions: { redirectUrl },
      embeddedWalletType: "user-wallet",
      autoConnect: true,
    });
  }
  return phantomSDK;
}

function getSlush() {
  if (!slushWallet) {
    const registration = registerSlushWallet("Locus", { origin: "https://my.slush.app" });
    if (registration) {
      slushWallet = registration.wallet;
      slushUnregister = registration.unregister;
    } else {
      slushWallet = getWallets().get().find((wallet) => wallet.name === "Slush");
    }
    if (!slushWallet) fail("Slush Wallet is unavailable.");
    slushWallet.features["standard:events"]?.on("change", () => disconnectEventsFor("slush"));
  }
  return slushWallet;
}

function sessionsFor(connector) {
  return [...liveSessions.values()].filter((session) => session.connector === connector);
}

function disconnectEventsFor(connector) {
  for (const session of sessionsFor(connector)) {
    emit(connector, "disconnected", session.connectionID);
    removePublicSession(session.connectionID);
  }
}

function solanaAddress(addresses) {
  const address = addresses.find((candidate) => candidate?.addressType === AddressType.solana)
    || addresses.find((candidate) => typeof candidate?.address === "string");
  return assertString(address?.address, "Phantom Solana address", 128);
}

async function connect(connector, payload) {
  const request = assertObject(payload.request, "pairing request");
  setStatus(`Waiting for ${connector === "phantom" ? "Phantom" : connector}…`);
  let session;
  if (connector === "metamask") {
    const networkID = selectedNetwork(connector, request);
    const chainID = CONNECTOR_NETWORKS.metamask[networkID];
    const { client } = await getMetaMask();
    const result = await client.connect({ chainIds: [chainID] });
    if (String(result.chainId).toLowerCase() !== chainID) fail("MetaMask selected an unapproved network.");
    session = makeSession(connector, request, assertString(result.accounts?.[0], "MetaMask account", 128),
      "evm", "MetaMask", "https://connect.metamask.io");
  } else if (connector === "phantom") {
    const networkID = selectedNetwork(connector, request);
    const sdk = getPhantom();
    const result = await sdk.connect({ provider: "phantom" });
    await sdk.solana.switchNetwork(CONNECTOR_NETWORKS.phantom[networkID]);
    session = makeSession(connector, request, solanaAddress(result.addresses || []),
      "solana", "Phantom-managed", "https://connect.phantom.app");
  } else if (connector === "slush") {
    const networkID = selectedNetwork(connector, request);
    const wallet = getSlush();
    const result = await wallet.features["standard:connect"].connect();
    const account = result.accounts?.[0] || wallet.accounts?.[0];
    if (!account?.chains?.includes(networkID)) fail("Slush did not expose the approved network.");
    const publicKey = account?.publicKey instanceof Uint8Array
      ? btoa(String.fromCharCode(...account.publicKey)) : null;
    session = makeSession(connector, request, assertString(account?.address, "Slush account", 128),
      "sui", "Slush", "https://my.slush.app", undefined, publicKey);
  } else {
    fail("That connector is unavailable.");
  }
  liveSessions.set(session.connectionID, session);
  persistPublicSession(session);
  setStatus(`${session.peerName} is connected. You can close this window.`);
  return session;
}

async function restoreOne(stored) {
  const request = {
    requestID: stored.connectionID,
    requestedNetworkIDs: stored.networkIDs,
    requestedMethods: stored.approvedMethods,
  };
  let address;
  if (stored.connector === "metamask") {
    const { provider } = await getMetaMask();
    const accounts = await provider.request({ method: "eth_accounts" });
    const chainID = await provider.request({ method: "eth_chainId" });
    if (String(chainID).toLowerCase() !== CONNECTOR_NETWORKS.metamask[stored.networkIDs[0]]) return null;
    address = accounts?.[0];
  } else if (stored.connector === "phantom") {
    const sdk = getPhantom();
    if (!sdk.isConnected()) return null;
    await sdk.solana.switchNetwork(CONNECTOR_NETWORKS.phantom[stored.networkIDs[0]]);
    address = solanaAddress(await sdk.getAddresses());
  } else if (stored.connector === "slush") {
    const wallet = getSlush();
    address = wallet.accounts?.find((account) => account.chains?.includes(stored.networkIDs[0]))?.address;
  }
  if (!address || address.toLowerCase() !== stored.accounts[0].address.toLowerCase()) return null;
  const session = makeSession(stored.connector, request, address, stored.accounts[0].chain,
    stored.peerName, stored.peerURL, stored);
  session.expiresAt = stored.expiresAt;
  liveSessions.set(session.connectionID, session);
  return session;
}

async function restore(connector) {
  const restored = [];
  for (const session of loadStoredSessions().filter((item) => item.connector === connector)) {
    try {
      const active = await restoreOne(session);
      if (active) restored.push(active);
      else removePublicSession(session.connectionID);
    } catch {
      removePublicSession(session.connectionID);
    }
  }
  return restored;
}

function validateExecution(connector, payload) {
  const wrapper = assertObject(payload.request, "execution request");
  const routed = assertObject(wrapper.request, "routed request");
  const prepared = assertObject(wrapper.prepared, "prepared transaction");
  const binding = assertObject(routed.binding, "request binding");
  const preparedBinding = assertObject(prepared.binding, "prepared binding");
  if (JSON.stringify(binding) !== JSON.stringify(preparedBinding)) fail("The request binding changed after review.");
  const routedPayload = assertObject(routed.payload, "routed request payload");
  if (JSON.stringify(routedPayload.action) !== JSON.stringify(prepared.action)) {
    fail("The requested action changed after review.");
  }
  if (binding.connector !== connector) fail("The connector binding is invalid.");
  const session = liveSessions.get(binding.connectionID);
  if (!session || Date.parse(session.expiresAt) <= Date.now()) fail("The wallet connection expired.");
  if (!session.accounts.some((account) => account.id === binding.accountID)) fail("The account is not approved.");
  if (!session.networkIDs.includes(binding.networkID)) fail("The network is not approved.");
  if (!session.approvedMethods.includes(binding.method)) fail("The method is not approved.");
  if (Date.parse(prepared.expiresAt) <= Date.now() || Date.parse(binding.expiresAt) <= Date.now()) {
    fail("The prepared transaction expired.");
  }
  if (prepared.accountAddress.toLowerCase() !== session.accounts[0].address.toLowerCase()) {
    fail("The prepared transaction account changed.");
  }
  return { wrapper, routed, prepared, binding, session };
}

async function execute(connector, payload) {
  const { prepared, binding, session } = validateExecution(connector, payload);
  const transaction = assertObject(prepared.payload, "prepared payload");
  let transactionID;
  if (connector === "metamask") {
    if (transaction.format !== "evm_eip1193") fail("MetaMask requires an EVM transaction.");
    const evm = assertObject(transaction.evm, "EVM transaction");
    const { provider } = await getMetaMask();
    const accounts = await provider.request({ method: "eth_accounts" });
    const chainID = await provider.request({ method: "eth_chainId" });
    if (accounts?.[0]?.toLowerCase() !== session.accounts[0].address.toLowerCase()
      || String(chainID).toLowerCase() !== evm.chainIDHex.toLowerCase()) {
      fail("MetaMask account or network changed after review.");
    }
    transactionID = await provider.request({
      method: "eth_sendTransaction",
      params: [{
        from: evm.from, to: evm.to, value: evm.valueHex, data: evm.dataHex,
        gas: evm.gasHex, maxFeePerGas: evm.maxFeePerGasHex,
        maxPriorityFeePerGas: evm.maxPriorityFeePerGasHex, nonce: evm.nonceHex,
      }],
    });
  } else if (connector === "phantom") {
    if (transaction.format !== "solana_base64") fail("Phantom requires a Solana transaction.");
    const sdk = getPhantom();
    const address = solanaAddress(await sdk.getAddresses());
    if (address !== session.accounts[0].address) fail("The Phantom account changed after review.");
    await sdk.solana.switchNetwork(CONNECTOR_NETWORKS.phantom[binding.networkID]);
    const bytes = decodeBase64(transaction.transactionBase64);
    let decoded;
    try { decoded = VersionedTransaction.deserialize(bytes); }
    catch { decoded = Transaction.from(bytes); }
    const result = await sdk.solana.signAndSendTransaction(decoded, {
      minContextSlot: transaction.minimumContextSlot,
    });
    transactionID = result.hash;
  } else if (connector === "slush") {
    if (transaction.format !== "sui_bcs_base64") fail("Slush requires a Sui transaction.");
    const wallet = getSlush();
    const account = wallet.accounts.find((candidate) => candidate.address === session.accounts[0].address);
    if (!account) fail("The Slush account changed after review.");
    const result = await wallet.features["sui:signAndExecuteTransaction"].signAndExecuteTransaction({
      account,
      chain: binding.networkID,
      transaction: SuiTransaction.from(decodeBase64(transaction.transactionBase64)),
    });
    transactionID = result.digest;
  } else {
    fail("That connector is unavailable.");
  }
  return { binding, transactionID: assertString(transactionID, "transaction id", 256), submittedAt: new Date().toISOString() };
}

async function disconnect(connector, connectionID) {
  assertString(connectionID, "connection id", 64);
  removePublicSession(connectionID);
  if (connector === "metamask") await metamaskClient?.disconnect?.();
  if (connector === "phantom") await phantomSDK?.disconnect?.();
  if (connector === "slush") await slushWallet?.features["standard:disconnect"]?.disconnect?.();
  return {};
}

async function suspend() {
  setStatus("Wallet connections are paused while Locus is inactive.");
  return {};
}

async function handle(command) {
  if (!configuration) fail("The wallet runtime is not configured.");
  assertObject(command, "command");
  const id = assertString(command.id, "command id", 64);
  const connector = assertString(command.connector, "connector", 32);
  const payload = assertObject(command.payload, "payload");
  let value;
  switch (command.operation) {
    case "restore": value = await restore(connector); break;
    case "connect": value = await connect(connector, payload); break;
    case "execute": value = await execute(connector, payload); break;
    case "cancel": value = await disconnect(connector, payload.requestID); break;
    case "disconnect": value = await disconnect(connector, payload.connectionID); break;
    case "suspend": value = await suspend(); break;
    default: fail("The wallet operation is unsupported.");
  }
  return JSON.stringify({ id, value, error: null });
}

window.LocusWalletConnections = Object.freeze({
  configure(value) {
    if (configuration) fail("The wallet runtime is already configured.");
    const config = assertObject(value, "configuration");
    configuration = Object.freeze({
      dappURL: assertString(config.dappURL, "dapp URL", 2048),
      metamaskRPCURLs: Object.freeze(assertObject(config.metamaskRPCURLs, "MetaMask provider URLs")),
      phantomAppID: typeof config.phantomAppID === "string" ? config.phantomAppID : "",
      phantomRedirectURL: typeof config.phantomRedirectURL === "string" ? config.phantomRedirectURL : "",
    });
    setStatus("Choose a wallet in Locus to begin.");
    return true;
  },
  async handle(command) {
    try { return await handle(command); }
    catch (error) {
      const id = typeof command?.id === "string" ? command.id : "invalid";
      return JSON.stringify({ id, value: null, error: String(error?.message || error).slice(0, 512) });
    }
  },
});

window.addEventListener("beforeunload", () => {
  slushUnregister?.();
});
