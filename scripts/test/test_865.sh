stack build --stack-yaml=stack-8.6.5.yaml --fast liquidhaskell:exe:liquid && stack test --stack-yaml=stack-8.6.5.yaml -j1 liquidhaskell:test --flag liquidhaskell:include --flag liquidhaskell:devel --ta="--liquid-runner \"stack --stack-yaml=/Users/adinapoli/work/clients/Ranjit_Jhala/lh/stack-8.6.5.yaml exec -- liquid \"" --ta="-p $1" --fast