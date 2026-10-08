#!/usr/bin/env python3
"""事件日志 CLI(shell 脚本埋点用)。

用法:
  ev.py log <type> <detail...>   # 追加一条事件,如: ev.py log runner "runner 启动"
  ev.py prune [天数]             # 清理普通事件(默认留7天,added 豁免)
"""
import os, sys

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "batch"))
from mp_retry_lib import log_event, prune_events

if len(sys.argv) >= 3 and sys.argv[1] == "log":
    # 支持 key=value 附加字段(须无空格),如: ev.py log scan state=fail 微信读书授权失效
    extras, words = {}, []
    for a in sys.argv[3:]:
        if "=" in a and " " not in a:
            k, v = a.split("=", 1)
            extras[k] = v
        else:
            words.append(a)
    log_event(sys.argv[2], detail=" ".join(words) or None, **extras)
elif len(sys.argv) >= 2 and sys.argv[1] == "prune":
    kept, dropped = prune_events(int(sys.argv[2]) if len(sys.argv) > 2 else 7)
    print(f"events kept={kept} dropped={dropped}")
else:
    print("usage: ev.py log <type> <detail...> | ev.py prune [days]", file=sys.stderr)
    sys.exit(2)
