#!/bin/bash
cd ./public
git init
git config user.name "turinglv"
git config user.email "332361566@qq.com"
git add .
git commit -m "Update Hexo Blog"
git push --force --quiet "https://${token}@${GH_REF}" master:master