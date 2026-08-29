" matrix.vim — phosphor-green colorscheme matching the Ghostty Matrix palette
set background=dark
hi clear
if exists("syntax_on")
  syntax reset
endif
let g:colors_name = "matrix"

hi Normal       ctermfg=46   ctermbg=NONE guifg=#00ff41 guibg=#0d0208
hi Comment      ctermfg=22   guifg=#008f11 cterm=italic gui=italic
hi Constant     ctermfg=120  guifg=#7dff9a
hi String       ctermfg=84   guifg=#4dff77
hi Number       ctermfg=120  guifg=#7dff9a
hi Identifier   ctermfg=40   guifg=#00d836
hi Function     ctermfg=48   guifg=#00ff87 cterm=bold gui=bold
hi Statement    ctermfg=46   guifg=#00ff41 cterm=bold gui=bold
hi Operator     ctermfg=40   guifg=#00d836
hi PreProc      ctermfg=34   guifg=#00b32c
hi Type         ctermfg=42   guifg=#00e05a cterm=bold gui=bold
hi Special      ctermfg=84   guifg=#4dff77
hi Todo         ctermfg=232  ctermbg=46 guifg=#0d0208 guibg=#00ff41 cterm=bold gui=bold
hi Error        ctermfg=196  ctermbg=NONE guifg=#ff4136 guibg=NONE cterm=bold gui=bold

hi LineNr       ctermfg=22   guifg=#008f11
hi CursorLineNr ctermfg=46   guifg=#00ff41 cterm=bold gui=bold
hi CursorLine   ctermbg=233  guibg=#0f1a0f cterm=NONE gui=NONE
hi Visual       ctermfg=232  ctermbg=40 guifg=#0d0208 guibg=#00d836
hi Search       ctermfg=232  ctermbg=46 guifg=#0d0208 guibg=#00ff41
hi IncSearch    ctermfg=232  ctermbg=84 guifg=#0d0208 guibg=#4dff77
hi MatchParen   ctermfg=232  ctermbg=48 guifg=#0d0208 guibg=#00ff87

hi StatusLine   ctermfg=46   ctermbg=234 guifg=#00ff41 guibg=#101510 cterm=bold gui=bold
hi StatusLineNC ctermfg=22   ctermbg=234 guifg=#008f11 guibg=#101510 cterm=NONE gui=NONE
hi VertSplit    ctermfg=22   ctermbg=NONE guifg=#008f11 guibg=NONE
hi Pmenu        ctermfg=40   ctermbg=234 guifg=#00d836 guibg=#101510
hi PmenuSel     ctermfg=232  ctermbg=46 guifg=#0d0208 guibg=#00ff41
hi Folded       ctermfg=28   ctermbg=233 guifg=#00a828 guibg=#0f1a0f
hi NonText      ctermfg=22   guifg=#008f11
hi SpecialKey   ctermfg=22   guifg=#008f11
hi Directory    ctermfg=48   guifg=#00ff87 cterm=bold gui=bold
hi Title        ctermfg=46   guifg=#00ff41 cterm=bold gui=bold
hi DiffAdd      ctermfg=46   ctermbg=22 guifg=#00ff41 guibg=#003b00
hi DiffDelete   ctermfg=196  ctermbg=NONE guifg=#ff4136
hi DiffChange   ctermfg=84   ctermbg=233 guifg=#4dff77 guibg=#0f1a0f
