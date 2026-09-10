import sys, json
sys.argv = ["x"] 
url = "http://127.0.0.1:53709/_VbpKrndEUY=/"
# 复用 vm_cpu 的连接逻辑
exec(open("tool/vm_cpu.py").read().split("vm = rpc")[0].replace("url = sys.argv[1]", "pass").replace("secs = int", "pass").replace("windows = int", "pass") if False else "")
