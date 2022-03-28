const { ethers, upgrades, waffle } = require("hardhat")
const { expect } = require("chai")
const IERC20ABI = require("../abis/IERC20ABI.json")
const routerABI = require("../abis/routerABI.json")

const USDCAddr = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
const WETHAddr = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"

const sRouterAddr = "0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F"
const uRouterAddr = "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D"

describe("Metapoly stake", () => {
    it("Should work with USDC", async () => {
        const [deployer, user] = await ethers.getSigners()

        // Deploy D33D
        const D33DFac = await ethers.getContractFactory("Token", deployer)
        const D33D = await upgrades.deployProxy(D33DFac, ["D33D", "D33D", 18])

        // Deploy USM
        const USMFac = await ethers.getContractFactory("USM", deployer)
        const USM = await upgrades.deployProxy(USMFac, [])

        // Deploy vD33D
        const vD33DFac = await ethers.getContractFactory("Token", deployer)
        const vD33D = await upgrades.deployProxy(vD33DFac, ["vD33D", "vD33D", 18])

        // Deploy DVD
        const DVD = await waffle.deployMockContract(deployer, IERC20ABI)

        // Deploy Treasury
        const treasuryFac = await ethers.getContractFactory("Treasury", deployer)
        const treasury = await upgrades.deployProxy(treasuryFac, [
            D33D.address,
            USDCAddr,
            ethers.utils.parseEther("0.1")
        ])

        // Deploy Staking
        const stakingFac = await ethers.getContractFactory("Staking", deployer)
        const staking = await upgrades.deployProxy(stakingFac, [
            ethers.constants.AddressZero, // _trustedForwarderAddress
            USM.address, // _USM
            ethers.utils.parseEther("5000") // _USMClaimLimit
        ])
        // console.log(staking.address)

        // Deploy sD33D
        const sD33DFac = await ethers.getContractFactory("StakingToken", deployer)
        const sD33D = await upgrades.deployProxy(sD33DFac, [
            "staking D33D", // name_
            "sD33D", // symbol_
            staking.address // stakingContract_
        ])
        // console.log(sD33D.address)

        // Set index for sD33D
        await sD33D.setIndex(ethers.utils.parseEther("1"))
        await expect(sD33D.setIndex(ethers.utils.parseEther("1"))).to.be.revertedWith("Cannot set INDEX again")

        // Deploy Distributor
        const distributorFac = await ethers.getContractFactory("Distributor", deployer)
        const distributor = await upgrades.deployProxy(distributorFac, [
            D33D.address, // D33D_
            treasury.address, // treasury_
            28800, // epochLength_
            (await deployer.provider.getBlock()).timestamp + 28800, // nextEpochTimestamp_
            deployer.address // admin_
        ])

        // Distributor add Staking
        await distributor.addRecipient(
            staking.address, // receiver_
            sD33D.address, // stakingToken_
            100 // rate_
        )

        // Treasury set Distributor as reward manager
        await treasury.toggle(7, distributor.address, ethers.constants.AddressZero)

        // Deploy stakingWarmup
        const stakingWarmupFac = await ethers.getContractFactory("StakingWarmup", deployer)
        const stakingWarmup = await upgrades.deployProxy(stakingWarmupFac)

        // Deploy USMMinter
        const USMMinterFac = await ethers.getContractFactory("USMMinter", deployer)
        const USMMinter = await upgrades.deployProxy(USMMinterFac, [
            USM.address, // _USM
            DVD.address, // _dvd
            D33D.address, // _d33d
            WETHAddr, // _weth
            USDCAddr, // _usdc
            uRouterAddr, // _dvdRouter
            sRouterAddr, // _d33dRouter
            ethers.constants.AddressZero // _biconomyForwarder
        ])

        // Allow USMMinter to mint USM
        await USM.setMinter(USMMinter.address)

        // Allow staking contract to mint USM
        await USMMinter.addAllowedContract(staking.address)

        // Initialize Staking
        await staking.initializeStaking(
            D33D.address, // _D33D
            sD33D.address, // _sD33D
            distributor.address, // distributor_
            stakingWarmup.address, // _stakingWarmup
            28800, // _epochLength
            0, // _firstEpochNumber
            (await deployer.provider.getBlock()).timestamp, // _firstEpochTimestamp
            deployer.address, // _DAO
            USMMinter.address, // _usmMinter
            vD33D.address // _vD33D
        )
        await expect(staking.initializeStaking(
            D33D.address, // _D33D
            sD33D.address, // _sD33D
            distributor.address, // distributor_
            stakingWarmup.address, // _stakingWarmup
            28800, // _epochLength
            0, // _firstEpochNumber
            (await deployer.provider.getBlock()).timestamp, // _firstEpochTimestamp
            deployer.address, // _DAO
            USMMinter.address, // _usmMinter
            vD33D.address // _vD33D
        )).to.be.revertedWith("Already initalized")

        // Add staking contract to stakingWarmup after initialize staking
        await stakingWarmup.addStakingContract(staking.address)

        // Deploy BondContract
        const bondFac = await ethers.getContractFactory("BondContract", deployer)
        const bond = await upgrades.deployProxy(bondFac, [
            D33D.address, // _D33D
            USDCAddr, // _principle
            treasury.address, // _treasury
            deployer.address, // _DAO
            ethers.constants.AddressZero, // _bondCalculator
            staking.address, // _staking
            deployer.address, // _admin
            ethers.constants.AddressZero, // _trustedForwarderAddress
        ])

        // Get some USDC
        const router = new ethers.Contract(sRouterAddr, routerABI, deployer)
        await router.swapETHForExactTokens(
            ethers.utils.parseUnits("13000", 6), [WETHAddr, USDCAddr], deployer.address, Math.ceil(Date.now() / 1000) + 31536000,
            {value: ethers.utils.parseEther("10")}
        )

        // Create supply for D33D
        await treasury.toggle(0, deployer.address, ethers.constants.AddressZero)
        const USDC = new ethers.Contract(USDCAddr, IERC20ABI, deployer)
        await USDC.approve(treasury.address, ethers.constants.MaxUint256)
        await treasury.deposit(ethers.utils.parseUnits("1000", 6), USDCAddr, ethers.utils.parseEther("10000"))
        // Donate Bond to solve transfer error for last redeem
        await D33D.mint(bond.address, ethers.utils.parseEther("0.01"))

        // Create liquidity for D33D-USDC
        await USDC.approve(sRouterAddr, ethers.constants.MaxUint256)
        await D33D.approve(sRouterAddr, ethers.constants.MaxUint256)
        await router.addLiquidity(
            D33D.address,
            USDCAddr,
            ethers.utils.parseEther("10000"),
            ethers.utils.parseUnits("10000", 6),
            0, 0,
            deployer.address,
            Math.ceil(Date.now() / 1000) + 31537000
        )

        // Whitelist Bond contract
        await treasury.toggle(
            0, // _managing
            bond.address, // _address
            ethers.constants.AddressZero // _calculator
        )

        // Initialize Bond
        await bond.initializeBondTerms(
            100, // _controlVariable
            432000, // _vestingTerm
            ethers.utils.parseEther("0.909"), // _minimumPrice
            100000, // _maxPayout
            0, // _fee
            ethers.utils.parseEther("10000"), // _maxDebt
            0 // _initialDebt
        )

        // Bond USDC
        await USDC.approve(bond.address, ethers.constants.MaxUint256)
        await bond.deposit(
            ethers.utils.parseUnits("1000", 6), // _amount
            (await bond.bondPrice()).mul(101).div(100), // _maxPrice
            deployer.address // _depositor
        )

        // Redeem D33D
        await network.provider.request({method: "evm_increaseTime", params: [86400*5]}) // 5 days
        await network.provider.send("evm_mine")
        await bond.redeem(deployer.address, false)
        // console.log(ethers.utils.formatEther(await D33D.balanceOf(deployer.address)))

        // Stake D33D
        await D33D.approve(staking.address, ethers.constants.MaxUint256)
        await staking.stake(await D33D.balanceOf(deployer.address), deployer.address)
        // console.log(ethers.utils.formatEther(await vD33D.balanceOf(deployer.address)))
        await staking.claimRewards() // Staking contract coverage

        // Redeem and Stake D33D
        await bond.deposit(
            ethers.utils.parseUnits("1000", 6), // _amount
            (await bond.bondPrice()).mul(101).div(100), // _maxPrice
            deployer.address // _depositor
        )
        await network.provider.request({method: "evm_increaseTime", params: [86400]})
        await network.provider.send("evm_mine")
        await bond.redeem(deployer.address, true)

        // Rebase
        await network.provider.request({method: "evm_increaseTime", params: [28800]})
        await network.provider.send("evm_mine")
        await staking.rebase()

        // Claim USM
        await staking.adjustRewardLimit(ethers.utils.parseEther("1")) // Staking contract coverage
        await staking.claimRewards()
        await staking.adjustRewardLimit(ethers.utils.parseEther("5000"))
        await staking.claimRewards()

        // Compound for more vD33D
        // for (let i = 0; i < 3; i ++) {
        await network.provider.request({method: "evm_increaseTime", params: [28800]})
        await network.provider.send("evm_mine")
        await staking.rebase()
        // }
        await staking.claimAndStakeD33D()
        // console.log(ethers.utils.formatEther(await vD33D.balanceOf(deployer.address)))

        // Distributor contract coverage
        await distributor.setAdjustment(0, true, 1, 101)
        await network.provider.request({method: "evm_increaseTime", params: [28800]})
        await network.provider.send("evm_mine")
        await staking.rebase()
        await distributor.setAdjustment(0, false, 1, 100)
        await network.provider.request({method: "evm_increaseTime", params: [28800]})
        await network.provider.send("evm_mine")
        await staking.rebase()
        await staking.rebase() // Staking contract coverage
        expect(await distributor.nextRewardFor(staking.address)).to.gt(1)

        // Unstake D33D
        // await network.provider.request({method: "evm_increaseTime", params: [28800]})
        // await network.provider.send("evm_mine")
        // await vD33D.approve(staking.address, ethers.constants.MaxUint256)
        // await staking.unStake(true)
        // console.log(ethers.utils.formatEther(await D33D.balanceOf(deployer.address)))
        // console.log(ethers.utils.formatEther(await vD33D.balanceOf(deployer.address)))
        // console.log(ethers.utils.formatEther(await USM.balanceOf(deployer.address)))

        await USMMinter.removeAllowedContract(staking.address) // USMMinter contract coverage
        await distributor.removeRecipient(staking.address, 0) // Distributor contract coverage
        await stakingWarmup.removeStakingContract(staking.address) // StakingWarmup contract coverage
        await expect(sD33D.rebase(0, 0)).to.be.revertedWith("Only staking contract") // StakingToken contract coverage
        // Staking contract coverage
        expect(await staking.index()).to.gt(1)
        await staking.setTrustedForwarder(user.address)
        expect(await staking.trustedForwarder()).to.eq(user.address)
        expect(await staking.versionRecipient()).to.eq("1")
        await network.provider.request({method: "evm_increaseTime", params: [60]})
        await network.provider.send("evm_mine")
        await staking.rebase()
    })
})