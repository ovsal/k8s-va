# Kubespray Submodule

This directory is a git submodule pointing to Kubespray v2.26.0.

To initialize after cloning this repository:
```bash
git submodule update --init --recursive
cd ansible/kubespray && git checkout v2.26.0
```

Required Python dependencies:
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r ansible/kubespray/requirements.txt
```
