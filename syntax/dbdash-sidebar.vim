" Syntax for the dbdash sidebar (filetype dbdash-sidebar).

if exists("b:current_syntax")
  finish
endif

syn match dbdashSidebarHeader '^DbDash Sidebar$'
syn match dbdashSidebarDirectory '^Directory:.*$'
syn match dbdashSidebarRunning '^▾.*$'
syn match dbdashSidebarStopped '^▸.*$'
syn match dbdashSidebarLegend '^▸ = Not running$'
syn match dbdashSidebarLegend '^▾ = Running$'
syn match dbdashSidebarIcon '[▸▾]'

hi def link dbdashSidebarHeader     Title
hi def link dbdashSidebarDirectory  Comment
hi def link dbdashSidebarRunning    String
hi def link dbdashSidebarStopped    Comment
hi def link dbdashSidebarLegend     PreProc
hi def link dbdashSidebarIcon       Special

let b:current_syntax = "dbdash-sidebar"
