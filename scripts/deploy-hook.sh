#!/bin/sh
# certbot 續期成功後由 --deploy-hook 呼叫，讓 nginx 重新載入新憑證。
#
# 這支腳本在 certbot 容器內執行，而該容器以 `pid: "service:nginx"` 與 nginx
# 共用 PID namespace——在那個 namespace 裡，nginx 的 master process 就是 PID 1。
# 所以 `kill -HUP 1` 送的是 nginx 的 graceful reload：舊 worker 會處理完手上的
# 連線才退出，服務不中斷。
#
# 先前的版本改用 curl 打 /var/run/docker.sock 的 Docker API。那需要把 docker.sock
# 掛進容器，等同把整台主機的 root 交給 certbot；掛載時寫的 :ro 只讓 socket 檔案
# 唯讀，對透過它送出的 API 呼叫沒有任何限制。那個做法還得在 entrypoint 裡
# apk add curl，多一條每次啟動都要連外的供應鏈依賴。
set -e

kill -HUP 1
echo "Sent HUP to nginx (PID 1 in the shared namespace)"
