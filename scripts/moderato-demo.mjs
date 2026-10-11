import {execFileSync} from 'node:child_process';
import {lstat, mkdir, readFile, realpath, rename, stat, writeFile} from 'node:fs/promises';
import {dirname, isAbsolute, relative, resolve, sep} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {createPublicClient, createWalletClient, defineChain, http, isAddress, keccak256, parseAbi, parseUnits} from 'viem';
import {generatePrivateKey, privateKeyToAccount} from 'viem/accounts';
import {tempoModerato} from 'viem/chains';

export const CHAIN_ID = 42431;
export const RPC_URL = 'https://rpc.moderato.tempo.xyz';
export const ALPHA_USD = '0x20c0000000000000000000000000000000000001';
export const ROLES = ['deployer', 'owner', 'executor', 'authority', 'recipient'];
const repository = fileURLToPath(new URL('../', import.meta.url));
const tokenAbi = parseAbi(['function decimals() view returns (uint8)', 'function currency() view returns (string)', 'function symbol() view returns (string)', 'function balanceOf(address) view returns (uint256)']);
const publicFields = ['schemaVersion','stage','network','chainId','rpcUrl','token','feeToken','tokenSymbol',...ROLES,'sourceRevision','verifiedSourceRevision','createdAt','factory','factoryCodeHash','deploymentTransactionHash','deploymentBlockNumber','compilerVersion','verifiedAt','fundedBalances','fundedAt','appUrl'];
export const publicManifest = value => Object.fromEntries(publicFields.filter(name => Object.hasOwn(value,name)).map(name => [name,value[name]]));
class DeploymentError extends Error {}
const requireValue = (condition, message) => {if (!condition) throw new DeploymentError(message);};
function checkOutputPath(settings) {
  if (!settings.walletDir) return;
  const difference = relative(settings.walletDir, settings.manifest);
  requireValue(difference && (difference === '..' || difference.startsWith(`..${sep}`) || isAbsolute(difference)), 'The public manifest must be outside the private wallet directory.');
}

export function options(argv) {
  const [command, ...args] = argv;
  requireValue(['wallets', 'fund', 'deploy', 'verify'].includes(command), 'Use wallets, fund, deploy or verify.');
  const parsed = {command, rpc: RPC_URL, token: ALPHA_USD, feeToken: ALPHA_USD, artifact: resolve(repository, 'out/AllowItTempoVaultFactory.sol/AllowItTempoVaultFactory.json')};
  const names = {'--wallet-dir':'walletDir', '--manifest':'manifest', '--rpc':'rpc', '--token':'token', '--fee-token':'feeToken', '--artifact':'artifact'};
  const seen = new Set();
  for (let index = 0; index < args.length; index += 2) {
    const name = names[args[index]], value = args[index + 1];
    requireValue(name && value && !value.startsWith('--') && !seen.has(name), 'Arguments must be unique named options with values.');
    seen.add(name); parsed[name] = value;
  }
  requireValue(parsed.manifest && isAbsolute(parsed.manifest) && (command === 'verify' || (parsed.walletDir && isAbsolute(parsed.walletDir))), 'Supply absolute --wallet-dir and --manifest paths; public verify only needs --manifest.');
  if (parsed.walletDir) requireValue(isAbsolute(parsed.walletDir), 'Wallet directory must be an absolute path.');
  const rpc = new URL(parsed.rpc);
  requireValue(rpc.protocol === 'https:' && !rpc.username && !rpc.password && !rpc.search && !rpc.hash, 'RPC must be HTTPS without credentials or query parameters.');
  requireValue(isAddress(parsed.token) && isAddress(parsed.feeToken) && !/^0x0{40}$/i.test(parsed.token) && !/^0x0{40}$/i.test(parsed.feeToken), 'Supply nonzero TIP-20 token and fee-token addresses.');
  if (parsed.walletDir) parsed.walletDir = resolve(parsed.walletDir);
  parsed.manifest = resolve(parsed.manifest); parsed.artifact = resolve(parsed.artifact);
  checkOutputPath(parsed);
  return parsed;
}

function revision() {return execFileSync('git', ['rev-parse', 'HEAD'], {cwd:repository, encoding:'utf8', stdio:['ignore','pipe','ignore']}).trim();}
async function publicWrite(path, value) {
  await mkdir(dirname(path), {recursive:true});
  const temporary = `${path}.${process.pid}.tmp`;
  await writeFile(temporary, JSON.stringify(publicManifest(value), null, 2) + '\n', {flag:'wx'});
  await rename(temporary, path);
}
async function secureDirectory(path, create = false) {
  requireValue(process.platform !== 'win32', 'Generate and read demo keys on a POSIX filesystem with owner-only permissions.');
  if (create) await mkdir(path, {recursive:true, mode:0o700});
  const directory = await lstat(path);
  requireValue(directory.isDirectory() && !directory.isSymbolicLink() && !(directory.mode & 0o077) && directory.uid === process.getuid(), 'Wallet directory must be owned by the current user, mode 0700, and not a symlink.');
  const canonical = await realpath(path);
  let gitDirectory;
  try {gitDirectory = execFileSync('git', ['-C', canonical, 'rev-parse', '--show-toplevel'], {encoding:'utf8', stdio:['ignore','pipe','ignore']}).trim();} catch {}
  requireValue(!gitDirectory, 'Wallet keys must be stored outside every Git working tree.');
  return canonical;
}
async function accounts(walletDir) {
  const directory = await secureDirectory(walletDir);
  const result = {};
  for (const role of ROLES) {
    const path = resolve(directory, `${role}.key`), info = await lstat(path);
    requireValue(info.isFile() && !info.isSymbolicLink() && !(info.mode & 0o077) && info.uid === process.getuid(), `The ${role} key must be an owner-only regular file (0600).`);
    const key = (await readFile(path, 'utf8')).trim();
    requireValue(/^0x[0-9a-f]{64}$/i.test(key), `The ${role} key file is invalid.`);
    result[role] = privateKeyToAccount(key);
  }
  requireValue(new Set(ROLES.map(role => result[role].address.toLowerCase())).size === ROLES.length, 'Demo wallet roles must have separate accounts.');
  return result;
}
async function manifestRead(path) {return JSON.parse(await readFile(path, 'utf8'));}
export function checkManifest(manifest, settings, wallets) {
  requireValue(manifest.schemaVersion === 1 && manifest.network === 'tempo:testnet' && manifest.chainId === CHAIN_ID, 'Manifest must target Moderato 42431.');
  for (const [name, value] of Object.entries({rpcUrl:settings.rpc, token:settings.token, feeToken:settings.feeToken, ...Object.fromEntries(ROLES.map(role => [role, wallets[role].address]))})) {
    requireValue(typeof manifest[name] === 'string' && manifest[name].toLowerCase() === value.toLowerCase(), `Manifest ${name} differs from the selected demo configuration.`);
  }
}
export async function makeWallets(settings) {
  checkOutputPath(settings);
  const directory = await secureDirectory(settings.walletDir, true);
  for (const role of ROLES) {
    let exists = false;
    try {await lstat(resolve(directory, `${role}.key`)); exists = true;} catch (error) {if (error.code !== 'ENOENT') throw error;}
    requireValue(!exists, 'Wallet initialization refuses to overwrite existing keys.');
  }
  let manifestExists = false;
  try {await stat(settings.manifest); manifestExists = true;} catch (error) {if (error.code !== 'ENOENT') throw error;}
  requireValue(!manifestExists, 'Wallet initialization refuses to overwrite an existing manifest.');
  const addresses = {};
  for (const role of ROLES) {
    const key = generatePrivateKey();
    await writeFile(resolve(directory, `${role}.key`), `${key}\n`, {flag:'wx', mode:0o600});
    addresses[role] = privateKeyToAccount(key).address;
  }
  const manifest = {schemaVersion:1, stage:'wallets-ready', network:'tempo:testnet', chainId:CHAIN_ID, rpcUrl:settings.rpc, token:settings.token, feeToken:settings.feeToken, tokenSymbol:null, ...addresses, sourceRevision:revision(), createdAt:new Date().toISOString()};
  await publicWrite(settings.manifest, manifest);
  return manifest;
}

export async function preflight(client, settings) {
  requireValue(await client.getChainId() === CHAIN_ID, 'RPC chain ID differs from Moderato 42431; no funding or deployment was sent.');
  let tokenSymbol;
  for (const token of new Set([settings.token, settings.feeToken])) {
    const code = await client.getCode({address:token});
    requireValue(code && code !== '0x', 'A configured TIP-20 token has no deployed code.');
    requireValue(await client.readContract({address:token, abi:tokenAbi, functionName:'decimals'}) === 6, 'Demo tokens must have six decimals.');
    requireValue(await client.readContract({address:token, abi:tokenAbi, functionName:'currency'}) === 'USD', 'Payment and fee tokens must use the USD currency.');
    const symbol = await client.readContract({address:token, abi:tokenAbi, functionName:'symbol'});
    requireValue(typeof symbol === 'string' && symbol.length > 0 && symbol.length <= 32, 'The TIP-20 token symbol is invalid.');
    if (token.toLowerCase() === settings.token.toLowerCase()) tokenSymbol = symbol;
  }
  return tokenSymbol;
}
const balance = (client, token, address) => client.readContract({address:token, abi:tokenAbi, functionName:'balanceOf', args:[address]});
async function fund(client, settings, wallets, manifest) {
  for (const role of ['deployer', 'owner', 'executor']) {
    const minimum = parseUnits(role === 'owner' ? '40' : '10', 6);
    const address = wallets[role].address;
    if (await balance(client, settings.feeToken, address) >= minimum && await balance(client, settings.token, address) >= minimum) continue;
    // One faucet call per account; an uncertain response never causes an automatic second call.
    await client.request({method:'tempo_fundAddress', params:[address]});
    let funded = false;
    for (let poll = 0; poll < 30; poll++) {
      if (await balance(client, settings.feeToken, address) >= minimum && await balance(client, settings.token, address) >= minimum) {funded = true; break;}
      await new Promise(done => setTimeout(done, 2_000));
    }
    requireValue(funded, `Faucet balance for ${role} is not confirmed; inspect it before retrying.`);
  }
  const fundedBalances = {};
  for (const role of ['deployer', 'owner', 'executor', 'recipient']) fundedBalances[role] = (await balance(client, settings.token, wallets[role].address)).toString();
  const result = {...manifest, fundedBalances, fundedAt:new Date().toISOString()};
  await publicWrite(settings.manifest, result);
  return result;
}
async function artifactRead(path) {
  const artifact = JSON.parse(await readFile(path, 'utf8'));
  const bytecode = artifact.bytecode?.object, runtime = artifact.deployedBytecode?.object;
  requireValue(/^0x[0-9a-f]+$/i.test(bytecode || '') && /^0x[0-9a-f]+$/i.test(runtime || ''), 'Build the factory with forge build before deployment; unresolved libraries are unsupported.');
  const metadata = typeof artifact.metadata === 'string' ? JSON.parse(artifact.metadata) : artifact.metadata;
  return {bytecode, runtimeHash:keccak256(runtime), compilerVersion:metadata?.compiler?.version || null};
}
export function checkDeploymentResume(manifest, runtimeHash) {
  requireValue(manifest.stage !== 'broadcasting', 'A previous broadcast has no recorded hash. Inspect the deployer nonce/receipt before any new deployment.');
  requireValue(!manifest.factoryCodeHash || manifest.factoryCodeHash.toLowerCase() === runtimeHash.toLowerCase(), 'Compiled factory runtime differs from the deployment manifest.');
  if (['pending', 'deployed'].includes(manifest.stage)) requireValue(/^0x[0-9a-f]{64}$/i.test(manifest.deploymentTransactionHash || ''), 'Deployment recovery requires the original transaction hash.');
  else requireValue(manifest.stage === 'wallets-ready', 'Unknown deployment stage.');
}
export function checkFactoryTransaction(transaction, manifest, artifact) {
  requireValue(BigInt(transaction.chainId ?? 0) === BigInt(CHAIN_ID) && transaction.type === 'tempo' && transaction.typeHex === '0x76', 'Factory deployment must be a native Tempo 0x76 transaction on Moderato 42431.');
  requireValue(transaction.from.toLowerCase() === manifest.deployer.toLowerCase() && transaction.feeToken?.toLowerCase() === manifest.feeToken.toLowerCase(), 'Deployment signer or fee token differs from the manifest.');
  const call = transaction.calls?.length === 1 ? transaction.calls[0] : null;
  requireValue(call && call.to == null && BigInt(call.value ?? 0) === 0n && call.data?.toLowerCase() === artifact.bytecode.toLowerCase(), 'Deployment must contain exactly the compiled factory creation call and zero native value.');
}
async function verify(client, settings, manifest, artifact) {
  requireValue(/^0x[0-9a-f]{64}$/i.test(manifest.deploymentTransactionHash || ''), 'The deployment manifest has no recorded transaction hash.');
  const receipt = await client.waitForTransactionReceipt({hash:manifest.deploymentTransactionHash, confirmations:2, timeout:180_000});
  requireValue(receipt.status === 'success' && receipt.contractAddress && isAddress(receipt.contractAddress), 'Factory deployment did not produce a successful contract creation receipt.');
  if (manifest.factory) requireValue(manifest.factory.toLowerCase() === receipt.contractAddress.toLowerCase(), 'Factory address differs from the original deployment receipt.');
  const transaction = await client.getTransaction({hash:manifest.deploymentTransactionHash});
  checkFactoryTransaction(transaction, manifest, artifact);
  const code = await client.getCode({address:receipt.contractAddress, blockNumber:receipt.blockNumber});
  requireValue(code && keccak256(code).toLowerCase() === artifact.runtimeHash.toLowerCase(), 'Deployed factory code hash differs from the compiled runtime.');
  const currentCode = await client.getCode({address:receipt.contractAddress});
  requireValue(currentCode && keccak256(currentCode).toLowerCase() === artifact.runtimeHash.toLowerCase(), 'Current factory code hash differs from the deployment receipt.');
  const finalityDeadline = Date.now() + 120_000;
  let finalized = false;
  do {
    const finalizedBlock = await client.getBlock({blockTag:'finalized'});
    if (finalizedBlock.number >= receipt.blockNumber) {finalized = true; break;}
    await new Promise(done => setTimeout(done, 2_000));
  } while (Date.now() < finalityDeadline);
  requireValue(finalized, 'Deployment is not finalized after the bounded wait; rerun verify without broadcasting.');
  const canonicalBlock = await client.getBlock({blockNumber:receipt.blockNumber});
  requireValue(canonicalBlock.hash === receipt.blockHash, 'Deployment receipt is not on the canonical chain.');
  const result = {...manifest, stage:'deployed', factory:receipt.contractAddress, factoryCodeHash:artifact.runtimeHash, deploymentBlockNumber:receipt.blockNumber.toString(), compilerVersion:artifact.compilerVersion, verifiedSourceRevision:revision(), verifiedAt:new Date().toISOString()};
  await publicWrite(settings.manifest, result);
  return result;
}
export async function run(settings) {
  if (settings.command === 'wallets') return makeWallets(settings);
  const manifest = await manifestRead(settings.manifest);
  const wallets = settings.command === 'verify' ? Object.fromEntries(ROLES.map(role => {
    requireValue(isAddress(manifest[role]) && !/^0x0{40}$/i.test(manifest[role]), `Public manifest ${role} address is invalid.`);
    return [role,{address:manifest[role]}];
  })) : await accounts(settings.walletDir);
  checkManifest(manifest, settings, wallets);
  const chain = defineChain({...tempoModerato, feeToken:settings.feeToken, rpcUrls:{default:{http:[settings.rpc]}}});
  const client = createPublicClient({chain, transport:http(settings.rpc, {retryCount:0, timeout:30_000})});
  manifest.tokenSymbol = await preflight(client, settings);
  if (settings.command === 'fund') return fund(client, settings, wallets, manifest);
  const artifact = await artifactRead(settings.artifact);
  checkDeploymentResume(manifest, artifact.runtimeHash);
  if (settings.command === 'deploy' && manifest.stage === 'wallets-ready') {
    requireValue(await balance(client, settings.feeToken, wallets.deployer.address) >= parseUnits('1', 6), 'Fund the deployer fee-token balance before deployment.');
    // Persist before broadcasting; if the RPC reply is lost, refuse a blind duplicate deployment.
    const wallet = createWalletClient({account:wallets.deployer, chain, transport:http(settings.rpc, {retryCount:0, timeout:30_000})});
    const request = await wallet.prepareTransactionRequest({data:artifact.bytecode, value:0n, feeToken:settings.feeToken});
    manifest.stage = 'broadcasting'; manifest.factoryCodeHash = artifact.runtimeHash; manifest.sourceRevision = revision();
    await publicWrite(settings.manifest, manifest);
    manifest.deploymentTransactionHash = await wallet.sendTransaction(request);
    manifest.stage = 'pending';
    await publicWrite(settings.manifest, manifest);
  }
  return verify(client, settings, manifest, artifact);
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  try {
    const settings = options(process.argv.slice(2));
    const result = await run(settings);
    // Every field printed here is public. Never print wallet objects or underlying RPC errors.
    console.log(JSON.stringify(publicManifest(result), null, 2));
  } catch (error) {
    console.error(error instanceof DeploymentError ? error.message : 'Deployment operation failed. Inspect public chain state before retrying; private keys and raw RPC errors are not logged.');
    process.exitCode = 1;
  }
}
