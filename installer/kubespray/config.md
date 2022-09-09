ssh 접속 설정 (root 로 로그인 해서 키생성 및 복사하여야함.)

- 컨트롤플레인
[root@master]$ ssh-keygen
[root@master]$ cat /root/.ssh/id_rsa.pub > /root/.ssh/authorized_keys

- 노드
[root@master]$ vi /root/.ssh/authorized_keys
