#!/bin/bash


#检查docker程序是否存在不存在就安装
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
systemctl start docker
systemctl enable docker


#定义数据
read -p "Your Mail:" mail_add 
read -p "Docker Num:" num 

clear

#数据展示
echo "The email you entered:"$mail_add
echo "Docker Num:":$num
clear

#循环启动docker
for ((i=1;i<=$num;i++))
do
	docker run -d --restart=on-failure notfourflow/p2pclient $mail_add
done
