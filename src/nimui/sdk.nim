## nimui/sdk — Component SDK Facade
##
## Exports:
## - permissions: explicit capability model (fs, network, process, clipboard, notifications)
## - contract: third-party block manifest, SemVer compatibility, and BlockRegistry
## - ui_blocks: 11 minimal UI blocks (Text, Button, Input, List, Table, Image, Tabs, Modal, Toast, FilePicker, Timer)
## - system_blocks: 6 gated system blocks (HTTP, JSON, SQLite, CSV, LocalStorage, Shell)

import ./sdk/permissions
import ./sdk/contract
import ./sdk/ui_blocks
import ./sdk/system_blocks

export permissions
export contract
export ui_blocks
export system_blocks
