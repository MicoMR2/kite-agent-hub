#!/usr/bin/env python3
"""
Kite Agent Hub — Local Onboarding Script
Generates a new EVM wallet locally. Private key never leaves this machine.

Usage:
  python agent_onboard.py [--rpc-url URL] [--chain-id ID] [--key-file PATH]

Requirements:
  pip install eth-account requests
"""

import argparse
import json
import os
import stat
import sys
import time

import requests

FAUCET_URL = "https://faucet.gokite.ai/"
EXPLORER   = "https://testnet.kitescan.ai/"
DEFAULT_RPC      = "https://rpc-testnet.gokite.ai/"
DEFAULT_CHAIN_ID = 2368
DEFAULT_KEY_FILE = os.path.expanduser("~/.kite/agent_key.json")


# ── Safety checks ─────────────────────────────────────────────────────────────

def warn_if_root():
    if os.name != "nt" and os.geteuid() == 0:
        print("\n⚠️  WARNING: Running as root. Private key files created as root")
        print("   are accessible to all root processes. Use a non-root account.")
        choice = input("   Continue anyway? (y/n): ").strip().lower()
        if choice != "y":
            sys.exit(1)


def check_deps():
    try:
        from eth_account import Account
        return Account
    except ImportError:
        print("Missing dependency. Run:\n  pip install eth-account requests")
        sys.exit(1)


# ── Key management ─────────────────────────────────────────────────────────────

def generate_wallet(Account):
    """Generate a new EVM wallet. Returns (private_key_hex, address)."""
    acct = Account.create()
    return acct.key.hex(), acct.address


def load_or_create_wallet(Account, key_file):
    """Load existing key file or generate a new wallet."""
    if os.path.exists(key_file):
        print(f"\n[!] Found existing key file: {key_file}")
        choice = input("    Use existing wallet? (y/n): ").strip().lower()
        if choice == "y":
            try:
                with open(key_file) as f:
                    data = json.load(f)
                acct = Account.from_key(data["private_key"])
                print(f"    Loaded wallet: {acct.address}")
                return data["private_key"], acct.address
            except Exception as e:
                print(f"    Failed to load key file ({e}) — generating new wallet.")

    print("\n[1] Generating new EVM wallet locally...")
    private_key, address = generate_wallet(Account)
    return private_key, address


def save_key_file(private_key, wallet_address, key_file):
    """Write key to ~/.kite/agent_key.json with chmod 600."""
    key_dir = os.path.dirname(key_file)
    os.makedirs(key_dir, exist_ok=True)

    data = {
        "wallet_address": wallet_address,
        "private_key": private_key,
        "chain": "kite-testnet",
        "chain_id": DEFAULT_CHAIN_ID
    }
    with open(key_file, "w") as f:
        json.dump(data, f, indent=2)

    # Restrict to owner read/write only (chmod 600)
    os.chmod(key_file, stat.S_IRUSR | stat.S_IWUSR)
    return key_file


# ── Chain interaction ──────────────────────────────────────────────────────────

def rpc_call(method, params, rpc_url):
    payload = {"jsonrpc": "2.0", "method": method, "params": params, "id": 1}
    try:
        resp = requests.post(rpc_url, json=payload, timeout=10)
        return resp.json().get("result")
    except Exception:
        return None


def get_balance_wei(address, rpc_url):
    result = rpc_call("eth_getBalance", [address, "latest"], rpc_url)
    if result is None:
        return None
    try:
        return int(result, 16)
    except ValueError:
        return None


def verify_vault_on_chain(vault_address, rpc_url):
    """Returns True if contract code exists at address, False if EOA, None on error."""
    code = rpc_call("eth_getCode", [vault_address, "latest"], rpc_url)
    if code is None:
        return None
    return code not in ("0x", "0x0", "", None)


# ── Main flow ──────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Kite Agent Hub — local wallet onboarding")
    parser.add_argument("--rpc-url",  default=DEFAULT_RPC,      help="Kite chain JSON-RPC URL")
    parser.add_argument("--chain-id", default=DEFAULT_CHAIN_ID, type=int, help="Chain ID")
    parser.add_argument("--key-file", default=DEFAULT_KEY_FILE, help="Path to store wallet key JSON")
    args = parser.parse_args()

    print("\n" + "="*60)
    print("  Kite Agent Hub — Wallet Onboarding")
    print("="*60)
    print(f"  RPC  : {args.rpc_url}")
    print(f"  Chain: {args.chain_id}")

    warn_if_root()
    Account = check_deps()

    # ── Step 1: Wallet ────────────────────────────────────────────────────────
    private_key, wallet_address = load_or_create_wallet(Account, args.key_file)
    saved_path = save_key_file(private_key, wallet_address, args.key_file)

    print(f"\n✅ Wallet address : {wallet_address}")
    print(f"✅ Key saved to   : {saved_path}  (chmod 600 — owner only)")
    print(f"   Private key is NOT printed here and will NOT be logged.")

    # ── Step 2: Balance ───────────────────────────────────────────────────────
    print(f"\n[2] Checking balance on Kite testnet...")
    balance_wei = get_balance_wei(wallet_address, args.rpc_url)

    if balance_wei is None:
        print(f"    ⚠️  RPC unreachable ({args.rpc_url}). Check your network.")
    elif balance_wei == 0:
        print(f"    Balance: 0 KITE")
        print(f"\n    Fund your wallet from the testnet faucet:")
        print(f"      URL     : {FAUCET_URL}")
        print(f"      Address : {wallet_address}")
        print(f"      Explorer: {EXPLORER}address/{wallet_address}")
        print("\n    Press Enter after funding (or Ctrl+C to exit and fund later).")
        try:
            input()
        except KeyboardInterrupt:
            print("\n\nExiting. Re-run after funding your wallet.")
            print_summary(wallet_address, None, saved_path)
            sys.exit(0)

        for attempt in range(6):
            balance_wei = get_balance_wei(wallet_address, args.rpc_url)
            if balance_wei and balance_wei > 0:
                print(f"    Balance: {balance_wei / 1e18:.6f} KITE ✅")
                break
            print(f"    Still 0... retrying in 5s ({attempt+1}/6)")
            time.sleep(5)
        else:
            print("    Still showing 0. Continuing — wallet may still be processing.")
    else:
        print(f"    Balance: {balance_wei / 1e18:.6f} KITE ✅")

    # ── Step 3: Vault address ─────────────────────────────────────────────────
    print("\n[3] TradingAgentVault address")
    print("    Enter vault address if you have one.")
    print("    Press Enter to skip (you can add it later in the dashboard).")
    vault_address = input("    Vault address (0x...): ").strip()

    if vault_address:
        if not vault_address.startswith("0x") or len(vault_address) != 42:
            print("    ⚠️  Invalid address format — skipping vault verification.")
            vault_address = None
        else:
            print(f"    Verifying vault on Kite testnet...")
            found = verify_vault_on_chain(vault_address, args.rpc_url)
            if found is True:
                print(f"    ✅ Contract found on-chain: {vault_address}")
            elif found is False:
                print(f"    ⚠️  No contract at {vault_address} — may not be deployed yet.")
                print(f"       Check: {EXPLORER}address/{vault_address}")
            else:
                print(f"    ⚠️  Could not verify vault (RPC timeout). Proceeding anyway.")

    print_summary(wallet_address, vault_address, saved_path)


def print_summary(wallet_address, vault_address, key_file):
    print("\n" + "="*60)
    print("  SUMMARY — paste these into the dashboard")
    print("="*60)
    print(f"\n  Wallet address : {wallet_address}")
    if vault_address:
        print(f"  Vault address  : {vault_address}")
    else:
        print(f"  Vault address  : (add later in dashboard)")
    print(f"\n  Key file       : {key_file}")
    print(f"  (Private key is in key file — set as Fly.io secret:)")
    print(f"  fly secrets set AGENT_PRIVATE_KEY=$(jq -r .private_key {key_file})")
    print(f"\nNext steps:")
    print("  1. https://kite-agent-hub.fly.dev/users/register — create account")
    print("  2. Click 'New Agent' → paste wallet + vault address + set limits")
    print("  3. Agent activates — Claude signals, trades settle on Kite chain")
    print("\n" + "="*60 + "\n")


if __name__ == "__main__":
    main()
