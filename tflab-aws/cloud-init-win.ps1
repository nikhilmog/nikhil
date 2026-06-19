<powershell>
# Windows VM bootstrap — creates labadmin local admin user
# Equivalent to Azure vm-win admin_username/admin_password configuration
net user labadmin "${admin_password}" /add
net localgroup Administrators labadmin /add
</powershell>
