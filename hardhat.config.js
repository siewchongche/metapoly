require("@nomiclabs/hardhat-waffle")
require('@openzeppelin/hardhat-upgrades');
require('solidity-coverage')
require("dotenv").config()

module.exports = {
    networks: {
        hardhat: {
            forking: {
                url: process.env.ALCHEMY_URL_MAINNET,
                blockNumber: 14449100,
            },
        },
    },
    solidity: {
        compilers: [
            {
                version: "0.8.13",
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 200,
                    },
                }
            },
        ]
    },
    mocha: {
        timeout: 3000000
    }
};