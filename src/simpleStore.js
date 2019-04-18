const nervos = require('./nervos')

const {
  contractAddress,
  abi
} = require("./deployed/firstForeverDeployed.js")

const simpleStoreContract = new nervos.base.Contract(abi, contractAddress)

const transaction = require('./transaction')

module.exports = {
  transaction,
  simpleStoreContract
}
