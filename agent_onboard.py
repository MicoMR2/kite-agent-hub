#!/usr/bin/env python3
"""
Kite Agent Hub — Local Onboarding Script
Generates a new EVM wallet locally (private key never leaves your machine)
and verifies a TradingAgentVault address on Kite testnet.

Usage:
  python agent_onboard.py

Requirements:
  pip install eth-account requests
"""

import os
import sys
import json
import time
import requests

def check_deps():
    try:
        from eth_account import Account
        return Account
    except ImportError:
        print("Missing dependency. Run: pip install eth-account requests")
        sys.exit(1)

def generate_wallet(Account):
    """Generate a new EVM private key and wallet address locally."""
    acct = Account.create()
    return acct.key.hex(), acct.address

def get_balance(address, rpc_url):
    """Check wallet balance via JSON-RPC."""
    payload = {
        "jsonrpc": "2.0",
        "method": "eth_getBalance",
        "params": [address, "latest"],
        "id": 1
    }
    try:
        resp = requests.post(rpc_url, json=payload, timeout=10)
        result = resp.json().get("result", "0x0")
        return int(result, 16)
    except Exception:
        return None

def verify_vault(vault_address, rpc_url):
    """Check that a vault address has deployed contract code on-chain."""
    payload = {
        "jsonrpc": "2.0",
        "method": "eth_getCode",
        "params": [vault_address, "latest"],
        "id": 1
    }
    try:
        resp = requests.post(rpc_url, json=payload, timeout=10)
        code = resp.json().get("result", "0x")
        return code not in ("0x", "0x0", None, "")
    except Exception:
        return None

def save_env(private_key, wallet_address, env_path=".env.agent"):
    """Write private key to a local .env file (never sent to server)."""
    with open(env_path, "w") as f:
        f.write(f"# Kite Agent Hub — local wallet config\n")
        f.write(f"# KEEP THIS FILE SECRET. Add to .gitignore.\n")
        f.write(f"AGENT_PRIVATE_KEY={private_key}\n")
        f.write(f"AGENT_WALLET_ADDRESS={wallet_address}\n")
    return env_path

def main():
    TESTNET_RPC = "https://rpc-testnet.gokite.ai/"
    FAUCET_URL  = "https://faucet.gokite.ai/"
    EXPLORER    = "https://testnet.kitescan.ai/"

    print("\n" + "="*60)
    print("  Kite Agent Hub — Wallet Onboarding")
    print("="*60)

    Account = check_deps()

    # ── Step 1: Check for existing key or generate new one ────────────────────
    env_path = ".env.agent"
    existing_key = None
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                if line.startswith("AGENT_PRIVATE_KEY="):
                    existing_key = line.strip().split("=", 1)[1]
                    break

    if existing_key:
        print(f"\n[!] Found existing key in {env_path}")
        choice = input("    Use existing key? (y/n): ").strip().lower()
        if choice == "y":
            try:
                acct = Account.from_key(existing_key)
                private_key = existing_key
                wallet_address = acct.address
                print(f"    Loaded wallet: {wallet_address}")
            except Exception:
                print("    Invalid key in .env.agent — generating new one.")
                private_key, wallet_address = generate_wallet(Account)
        else:
            private_key, wallet_address = generate_wallet(Account)
    else:
        print("\n[1] Generating new EVM wallet locally...")
        private_key, wallet_address = generate_wallet(Account)

    env_file = save_env(private_key, wallet_address, env_path)
    print(f"\n✅ Wallet address : {wallet_address}")
    print(f"✅ Private key saved to {env_file} (never sent to server)")
    print(f"\n⚠️  Add {env_file} to your .gitignore if not already there.")

    # ── Step 2: Check balance ─────────────────────────────────────────────────
    print(f"\n[2] Checking balance on Kite testnet...")
    balance_wei = get_balance(wallet_address, TESTNET_RPC)

    if balance_wei is None:
        print("    Could not connect to Kite testnet RPC. Check your network.")
    elif balance_wei == 0:
        print(f"    Balance: 0 KITE")
        print(f"\n    Fund your wallet from the testnet faucet:")
        print(f"    {FAUCET_URL}")
        print(f"    Wallet: {wallet_address}")
        print(f"\n    View on explorer: {EXPLORER}address/{wallet_address}")
        print("\n    [Waiting for you to fund the wallet...]")
        print("    Press Enter once funded (or Ctrl+C to exit and fund later).")
        try:
            input()
        except KeyboardInterrupt:
            print("\n\nExiting. Re-run this script after funding your wallet.")
            print_summary(wallet_address, None, env_file)
            sys.exit(0)

        # Re-check balance
        for attempt in range(5):
            balance_wei = get_balance(wallet_address, TESTNET_RPC)
            if balance_wei and balance_wei > 0:
                break
            print(f"    Still 0... checking again in 5s ({attempt+1}/5)")
            time.sleep(5)

        if not balance_wei or balance_wei == 0:
            print("    Still showing 0. Proceed anyway (wallet may still be funded).")
        else:
            kite = balance_wei / 1e18
            print(f"    Balance: {kite:.6f} KITE ✅")
    else:
        kite = balance_wei / 1e18
        print(f"    Balance: {kite:.6f} KITE ✅")

    # ── Step 3: Vault address ─────────────────────────────────────────────────
    print("\n[3] TradingAgentVault address")
    print("    If you have a vault address, enter it now.")
    print("    If not, press Enter to skip (you can add it later in the dashboard).")
    vault_address = input("    Vault address (0x...): ").strip()

    verified = None
    if vault_address:
        if not vault_address.startswith("0x") or len(vault_address) != 42:
            print("    Invalid address format — skipping vault verification.")
            vault_address = None
        else:
            print(f"    Verifying vault on Kite testnet...")
            verified = verify_vault(vault_address, TESTNET_RPC)
            if verified:
                print(f"    ✅ Vault found on-chain: {vault_address}")
            elif verified is False:
                print(f"    ⚠️  No contract found at {vault_address} — may not be deployed yet.")
            else:
                print(f"    Could not verify vault (RPC timeout). Proceeding anyway.")

    # ── Summary ───────────────────────────────────────────────────────────────
    print_summary(wallet_address, vault_address, env_file)

def print_summary(wallet_address, vault_address, env_file):
    print("\n" + "="*60)
    print("  SETUP SUMMARY — paste these into the dashboard")
    print("="*60)
    print(f"\n  Wallet address : {wallet_address}")
    if vault_address:
        print(f"  Vault address  : {vault_address}")
    else:
        print(f"  Vault address  : (not set — add in dashboard later)")
    print(f"\n  Private key    : stored in {env_file}")
    print(f"\nNext steps:")
    print("  1. Go to https://kite-agent-hub.fly.dev/users/register")
    print("  2. Create an account")
    print("  3. Click 'New Agent' → paste wallet address + vault address")
    print("  4. Set spending limits (e.g. $10/day, $1/trade)")
    print("  5. Agent goes live — Claude generates signals, trades execute on Kite chain")
    print(f"\n  Set AGENT_PRIVATE_KEY in Fly.io secrets or your local server:")
    print(f"  fly secrets set AGENT_PRIVATE_KEY=<your_key>")
    print("\n" + "="*60 + "\n")

if __name__ == "__main__":
    main()
