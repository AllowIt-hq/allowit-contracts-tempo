import assert from 'node:assert/strict';
import {mkdtemp, readFile, rm, stat} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import test from 'node:test';
import {ALPHA_USD, CHAIN_ID, ROLES, RPC_URL, checkDeploymentResume, checkManifest, makeWallets, options, preflight, publicManifest} from './moderato-demo.mjs';

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
