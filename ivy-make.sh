#! /bin/bash

### ivy-make.sh --- refactor helm-make.el to ivy-make.el

## Copyright (C) 2019 Ernst M. van der Linden

## Author: Ernst M. van der Linden <ernst.vanderlinden@ernestoz.com>
## URL: https://github.com/ernstvanderlinden/ivy-make
## Version: 0.2.0
## Keywords: makefile

## This file is free software; you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by
## the Free Software Foundation; either version 3, or (at your option)
## any later version.

## This program is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
## GNU General Public License for more details.

## For a full copy of the GNU General Public License
## see <http://www.gnu.org/licenses/>.

### Commentary:
##
## File location of helm-make.el is expected to be in ../helm-make/
## If not, please change HELM_MAKE_FILE or use a symlink.

### Code:

HELM_MAKE_FILE="../helm-make/helm-make.el"

echo -n "Refactor: $HELM_MAKE_FILE --> ivy-make.el ..."
cp $HELM_MAKE_FILE ivy-make.el

cat ivy-make.el| \
    sed "\
s/helm-make/ivy-make/g ;
s/helm--make/ivy--make/g ;
s/defcustom ivy-make-completion-method 'helm/defcustom ivy-make-completion-method 'ivy/g ;
/.\+(require 'helm)/d ;
s/\`helm/\`ivy/g
s/\(;;.URL:.https:\/\/github.com\/abo-abo\/\).\+$/\1helm-make/g
s/\(;;;.ivy-make\.el.\+\)helm$/\1ivy/g ;
" -i ivy-make.el 

# s/;;.\(URL:.https:\/\/github.com\/abo-abo\/\).\+$/;; Author-\1helm-make\n\
# ;; URL: https:\/\/github.com\/ernstvanderlinden\/ivy-make/g

echo -n "done."
