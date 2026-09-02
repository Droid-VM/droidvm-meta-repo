# Ubuntu 26.04
```
apt update
apt install -y linux-headers-$(uname -r)
apt install -y vulkan-tools vkmark kde-plasma-desktop
apt install -y ./*.deb

# Create user
useradd -s /bin/bash user01
mkdir /home/user01
chown -R user01:user01 /home/user01
usermod -aG sudo user01
echo "user01:password01" | sudo chpasswd

INSTALL_MC=false
if [ "$INSTALL_MC" = true ]; then
    apt install -y openjdk-26-jre
    curl -L "https://hmcl.glavo.site/download/HMCL-3.16.3.sh" -o /home/user01/hmcl
    chmod 755 /home/user01/hmcl
    mkdir -p /home/user01/.hmcl/config
    echo '{"$schema":"https://schemas.glavo.site/hmcl/accounts/1.0.0","accounts":[{"type":"offline","accountID":"account:11111111-2222-3333-4444-555555555555","profileID":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","profileName":"TestUser01"}]}' > /home/user01/.hmcl/config/accounts.json
    chown -R user01:user01 /home/user01/
fi

```

Remember to turn on virtio-gpu in the VM settings, enjoy the 3D accelerated VM!
