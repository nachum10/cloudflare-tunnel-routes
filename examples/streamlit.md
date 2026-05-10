# Expose a Streamlit app

Streamlit's hosted "Streamlit Cloud" works for many cases, but a local tunnel is faster to iterate on and keeps your data local.

## App

`app.py`:

```python
import streamlit as st

st.title("Local dashboard")
name = st.text_input("Name", "World")
st.write(f"Hello, {name}!")
```

## Run + expose

```bash
# 1. Start Streamlit on a fixed port, bound to localhost only
streamlit run app.py \
    --server.address 127.0.0.1 \
    --server.port 8501 \
    --server.headless true &

# 2. Add the route
bash scripts/add-route.sh dash.example.com 8501 \
    --comment "Streamlit local dashboard"

# 3. Verify
curl -sSI https://dash.example.com/ | head -1
#   HTTP/2 200
```

## Notes

- Streamlit websockets work over the tunnel — you don't need any extra config.
- If you see "Please make sure your network connection is active" in the browser, check that `--server.address 127.0.0.1` is set. Binding to `0.0.0.0` is fine too, but the tunnel only needs `127.0.0.1`.
- Use `--diff` to preview the change before writing:

  ```bash
  bash scripts/add-route.sh dash.example.com 8501 --diff
  ```
