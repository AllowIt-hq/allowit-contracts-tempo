import assert from 'node:assert/strict';
import {mkdtemp, readFile, rm, stat} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {ALPHA_USD, CHAIN_ID, ROLES, RPC_URL, checkDeploymentResume, checkFactoryTransaction, checkManifest, makeWallets, options, preflight, publicManifest} from './moderato-demo.mjs';

test('wallet initialization creates separate private files and a public manifest, and preserves existing keys', async () => {
  const root = await mkdtemp(join(tmpdir(), 'tempo-demo-'));
  try {
    const settings = {walletDir:join(root,'private'), manifest:join(root,'public','deployment.json'), rpc:RPC_URL, token:ALPHA_USD, feeToken:ALPHA_USD};
    const manifest = await makeWallets(settings);
    assert.equal(new Set(ROLES.map(role => manifest[role])).size, 5);
    const keys = [];
    for (const role of ROLES) {
      const path = join(settings.walletDir, `${role}.key`);
      keys.push((await readFile(path,'utf8')).trim());
      assert.equal((await stat(path)).mode & 0o777, 0o600);
    }
    const publicJson = await readFile(settings.manifest,'utf8');
    for (const key of keys) assert.ok(!publicJson.includes(key));
    await assert.rejects(makeWallets(settings), /refuses to overwrite/);
    assert.equal((await readFile(join(settings.walletDir,'owner.key'),'utf8')).trim(), keys[1]);
  } finally {await rm(root, {recursive:true, force:true});}
});

test('command parsing rejects credential-bearing endpoints, absent private paths and duplicate options', () => {
  const base = ['deploy','--wallet-dir','/tmp/keys','--manifest','/tmp/deployment.json'];
  assert.equal(options(base).rpc, RPC_URL);
  assert.throws(() => options([...base,'--rpc','https://rpc.example/?key=secret']), /without credentials/);
  assert.throws(() => options([...base,'--rpc','http://127.0.0.1:8545']), /HTTPS/);
  assert.throws(() => options([...base,'--manifest','/tmp/other.json']), /unique/);
  assert.throws(() => options(['deploy']), /absolute/);
  assert.equal(options(['verify','--manifest','/tmp/deployment.json']).walletDir, undefined);
});

test('wrong-chain preflight stops before token reads or faucet/deployment requests', async () => {
  let tokenReads = 0;
  await assert.rejects(preflight({getChainId:async()=>4217, getCode:async()=>{tokenReads++; return '0x01';}}, {token:ALPHA_USD,feeToken:ALPHA_USD}), /Moderato 42431/);
  assert.equal(tokenReads, 0);
});

test('deployment recovery refuses unknown broadcasts and changed runtime', () => {
  const hash = `0x${'12'.repeat(32)}`;
  assert.throws(() => checkDeploymentResume({stage:'broadcasting'}, hash), /nonce\/receipt/);
  assert.throws(() => checkDeploymentResume({stage:'pending',factoryCodeHash:hash}, hash), /original transaction hash/);
  assert.throws(() => checkDeploymentResume({stage:'deployed',factoryCodeHash:`0x${'34'.repeat(32)}`,deploymentTransactionHash:hash}, hash), /differs/);
  assert.doesNotThrow(() => checkDeploymentResume({stage:'pending',factoryCodeHash:hash,deploymentTransactionHash:hash}, hash));
});

test('a manifest cannot silently select another role, token or chain', () => {
  const wallets = Object.fromEntries(ROLES.map((role,index)=>[role,{address:`0x${String(index+1).padStart(40,'0')}`} ]));
  const settings = {rpc:RPC_URL,token:ALPHA_USD,feeToken:ALPHA_USD};
  const manifest = {schemaVersion:1,network:'tempo:testnet',chainId:CHAIN_ID,rpcUrl:RPC_URL,token:ALPHA_USD,feeToken:ALPHA_USD,...Object.fromEntries(ROLES.map(role=>[role,wallets[role].address]))};
  assert.doesNotThrow(()=>checkManifest(manifest,settings,wallets));
  assert.throws(()=>checkManifest({...manifest,executor:wallets.owner.address},settings,wallets),/executor differs/);
  assert.throws(()=>checkManifest({...manifest,chainId:4217},settings,wallets),/Moderato/);
});

test('unknown private fields are excluded from persisted and printed manifests', () => {
  assert.deepEqual(publicManifest({chainId:CHAIN_ID, owner:'public address', privateKey:'secret', authorization:'secret', rpcResponse:{secret:'value'}}), {chainId:CHAIN_ID,owner:'public address'});
});

test('factory receipt verification binds the native Tempo creation call, chain, fee token and signer', () => {
  const manifest = {deployer:`0x${'12'.repeat(20)}`,feeToken:ALPHA_USD};
  const artifact = {bytecode:'0x1234'};
  const transaction = {chainId:CHAIN_ID,type:'tempo',typeHex:'0x76',from:manifest.deployer,feeToken:ALPHA_USD,calls:[{data:artifact.bytecode,value:0n}]};
  assert.doesNotThrow(()=>checkFactoryTransaction(transaction,manifest,artifact));
  assert.throws(()=>checkFactoryTransaction({...transaction,type:'eip1559'},manifest,artifact),/native Tempo/);
  assert.throws(()=>checkFactoryTransaction({...transaction,chainId:4217},manifest,artifact),/Moderato/);
  assert.throws(()=>checkFactoryTransaction({...transaction,calls:[...transaction.calls,...transaction.calls]},manifest,artifact),/exactly/);
  assert.throws(()=>checkFactoryTransaction({...transaction,calls:[{to:manifest.deployer,data:artifact.bytecode}]},manifest,artifact),/creation call/);
  assert.throws(()=>checkFactoryTransaction({...transaction,feeToken:manifest.deployer},manifest,artifact),/fee token/);
});

test('TIP-20 preflight rejects a non-USD six-decimal token before funding', async () => {
  const client = {getChainId:async()=>CHAIN_ID,getCode:async()=>'0x01',readContract:async({functionName})=>functionName==='decimals'?6:'EUR'};
  await assert.rejects(preflight(client,{token:ALPHA_USD,feeToken:ALPHA_USD}),/USD currency/);
});
