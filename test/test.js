const { ethers, upgrades } = require("hardhat")

describe("Test", () => {
    // it("Should work", async () => {
    //     const [deployer] = await ethers.getSigners()

    //     const testFac = await ethers.getContractFactory("Test", deployer)
    //     const test = await upgrades.deployProxy(testFac, [1])

    //     await test.setNum(2)

    //     console.log(await test.num())
    //     console.log(await test.owner())
    //     // 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
    // })

    // it("Should work", async () => {
    //     const [deployer] = await ethers.getSigners()

    //     const stakingFac = await ethers.getContractFactory("Staking", deployer)
    //     const staking = await upgrades.deployProxy(stakingFac, [])

    //     console.log(await staking.owner())
    //     // 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
    // })
})