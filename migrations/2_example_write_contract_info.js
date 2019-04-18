const fs = require('fs')
const path = require('path')
const Game = artifacts.require('Game')

module.exports = function(deployer) {
  deployer.deploy(Game, 'test', { overwrite: false }).then((contract) => {

    const dirpath = path.resolve(process.cwd(), './src/deployed')
    fs.existsSync(dirpath) || fs.mkdirSync(dirpath)
    const fpath = path.resolve(dirpath, 'gameDeployed.js')
    const f = fs.openSync(fpath, 'w+')

    let data = ''
    data += `const contractAddress = ${JSON.stringify(contract.address)}\n`
    data += `const abi = ${JSON.stringify(contract.abi)}\n\n`
    data += `export {contractAddress, abi}\n`

    fs.writeFileSync(f, data)
  })
}
