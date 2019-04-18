module.exports = {
  // See <http://truffleframework.com/docs/advanced/configuration>
  // to customize your Truffle configuration!
  // in windows env you should delete truffle.js, or you would get error
  compilers: {
    solc: {
      version: "0.4.24", // A version or constraint - Ex. "^0.5.0"
      settings: {
        optimizer: {
          enabled: true,
          // runs: <number>   // Optimize for how many times you intend to run the code
        }
      }
    }
  },
  networks: {
    development: {
      host: '121.196.200.225', // your host
      port: 1337,
      network_id: '*',
      privateKey: '0x31c336bf63f63d832d2313e26c224ca8d2100eca4ce86c87d3b5be6a0c56616b',
      // fromAddr: '0x854AeCB986534E665576D23ffb52C9b89D4e4814',
      quota: 953000
    },
  },
}