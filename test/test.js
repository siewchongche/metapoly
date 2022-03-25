const { ethers, upgrades, waffle } = require("hardhat")
const { expect } = require("chai")
const IERC20ABI = require("../abis/IERC20ABI.json")
const routerABI = require("../abis/routerABI.json")
const factoryABI = require("../abis/factoryABI.json")

const USDCAddr = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
const WETHAddr = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
const SANDAddr = "0x3845badade8e6dff049820680d1f14bd3903a5d0"

const sRouterAddr = "0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F"
const sFactoryAddr = "0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac"
const uRouterAddr = "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D"

const SANDOracleAddr = "0x35E3f7E558C04cE7eEE1629258EcbbA03B36Ec56"
const ETHOracleAddr = "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419"

describe("Metapoly bond", () => {
    before(async () => {
        const [deployer] = await ethers.getSigners()
        // Get some USDC
        const sRouter = new ethers.Contract(sRouterAddr, routerABI, deployer)
        await sRouter.swapETHForExactTokens(
            ethers.utils.parseUnits("20000", 6), [WETHAddr, USDCAddr], deployer.address, Math.ceil(Date.now() / 1000),
            {value: ethers.utils.parseEther("10")}
        )

        // Get some SAND
        const uRouter = new ethers.Contract(uRouterAddr, routerABI, deployer)
        await uRouter.swapETHForExactTokens(
            ethers.utils.parseEther("1000"), [WETHAddr, SANDAddr], deployer.address, Math.ceil(Date.now() / 1000),
            {value: ethers.utils.parseEther("10")}
        )
    })

    it("Should work with NFT", async () => {
        const [deployer] = await ethers.getSigners()

        // Deploy D33D
        const D33DFac = await ethers.getContractFactory("Token", deployer)
        const D33D = await upgrades.deployProxy(D33DFac, ["D33D", "D33D", 18])
        await D33D.mint(D33D.address, ethers.utils.parseEther("10000"))

        // Deploy NFT
        const nftFac = await ethers.getContractFactory("NFT", deployer)
        const nft = await upgrades.deployProxy(nftFac, ["NFT", "NFT"])
        await nft.mint(deployer.address)

        // Deploy Treasury
        const treasuryFac = await ethers.getContractFactory("Treasury", deployer)
        const treasury = await upgrades.deployProxy(treasuryFac, [
            D33D.address,
            USDCAddr,
            ethers.utils.parseEther("0.1")
        ])
        // console.log(treasury.address)

        // Deploy BondCalc
        const bondCalcFac = await ethers.getContractFactory("BondCalcNFT", deployer)
        const bondCalc = await upgrades.deployProxy(bondCalcFac, [
            5000, // markdownPerc_
            ethers.constants.AddressZero, // nftOracle_
            ETHOracleAddr // ethOracle_
        ])
        await bondCalc.setPrice(ethers.utils.parseEther("2.47"))
        // console.log(bondCalc.address)

        // console.log(ethers.utils.formatEther(await bondCalc.getRawPrice())) // 7462.3053556792

        // Deploy Staking
        const mockStaking = await waffle.deployMockContract(deployer, IERC20ABI)

        // Deploy BondContract
        const bondFac = await ethers.getContractFactory("BondContractNFT", deployer)
        const bond = await upgrades.deployProxy(bondFac, [
            D33D.address, // _D33D
            nft.address, // _principle
            treasury.address, // _treasury
            deployer.address, // _DAO
            bondCalc.address, // _bondCalculator
            mockStaking.address, // _staking
            deployer.address, // _admin
            ethers.constants.AddressZero, // _trustedForwarderAddress
        ])

        // Initialize Bond
        await bond.initializeBondTerms(
            600, // _controlVariable
            432000, // _vestingTerm
            ethers.utils.parseEther("0.909"), // _minimumPrice
            100000, // _maxPayout
            0, // _fee
            ethers.utils.parseEther("10000"), // _maxDebt
            0 // _initialDebt
        )

        // Donate Bond to solve transfer error for last redeem
        await D33D.mint(bond.address, ethers.utils.parseEther("0.01"))

        // Whitelist Bond contract
        await treasury.toggle(
            8, // _managing
            bond.address, // _address
            ethers.constants.AddressZero // _calculator
        )

        // Whitelist WETH
        await treasury.toggle(
            9, // _managing
            nft.address, // _address
            bondCalc.address // _calculator
        )

        // Bond D33DUSDC
        await nft.approve(bond.address, 0)
        await bond.deposit(
            0, // _tokenId
            (await bond.bondPrice()).mul(101).div(100), // _maxPrice
            deployer.address // _depositor
        )

        // Redeem D33D
        await network.provider.request({method: "evm_increaseTime", params: [86400*5]}) // 5 days
        await network.provider.send("evm_mine")
        await bond.redeem(deployer.address, false)
        // console.log(ethers.utils.formatEther(await D33D.balanceOf(deployer.address)))
    })

    it("Should work with LP", async () => {
        const [deployer] = await ethers.getSigners()

        // Deploy D33D
        const D33DFac = await ethers.getContractFactory("Token", deployer)
        const D33D = await upgrades.deployProxy(D33DFac, ["D33D", "D33D", 18])
        await D33D.mint(deployer.address, ethers.utils.parseEther("10000"))

        // Deploy Treasury
        const treasuryFac = await ethers.getContractFactory("Treasury", deployer)
        const treasury = await upgrades.deployProxy(treasuryFac, [
            D33D.address,
            USDCAddr,
            ethers.utils.parseEther("0.1")
        ])

        // Get some USDC
        const router = new ethers.Contract(sRouterAddr, routerABI, deployer)
        // await router.swapETHForExactTokens(
        //     ethers.utils.parseUnits("10000", 6), [WETHAddr, USDCAddr], deployer.address, Math.ceil(Date.now() / 1000),
        //     {value: ethers.utils.parseEther("10")}
        // )
        const USDC = new ethers.Contract(USDCAddr, IERC20ABI, deployer)

        // Add liquidity D33D-USDC
        await USDC.approve(sRouterAddr, ethers.constants.MaxUint256)
        await D33D.approve(sRouterAddr, ethers.constants.MaxUint256)
        await router.addLiquidity(D33D.address, USDCAddr, ethers.utils.parseEther("10000"), ethers.utils.parseUnits("10000", 6), 0, 0, deployer.address, Math.ceil(Date.now() / 1000) + 86400 * 5)
        const factory = new ethers.Contract(sFactoryAddr, factoryABI, deployer)
        const D33DUSDCAddr = await factory.getPair(D33D.address, USDC.address) 
        const D33DUSDC = new ethers.Contract(D33DUSDCAddr, IERC20ABI, deployer)

        // Deploy BondCalc
        const bondCalcFac = await ethers.getContractFactory("BondCalcD33DUSDC", deployer)
        const bondCalc = await upgrades.deployProxy(bondCalcFac, [
            5000, // markdownPerc_
            D33DUSDC.address, // _pair
            sRouterAddr, // _router
            D33D.address, // _D33D
            USDCAddr // _USDC
        ])

        // Deploy Staking
        const mockStaking = await waffle.deployMockContract(deployer, IERC20ABI)

        // Deploy BondContract
        const bondFac = await ethers.getContractFactory("BondContract", deployer)
        const bond = await upgrades.deployProxy(bondFac, [
            D33D.address, // _D33D
            D33DUSDCAddr, // _principle
            treasury.address, // _treasury
            deployer.address, // _DAO
            bondCalc.address, // _bondCalculator
            mockStaking.address, // _staking
            deployer.address, // _admin
            ethers.constants.AddressZero, // _trustedForwarderAddress
        ])

        // Initialize Bond
        await bond.initializeBondTerms(
            600, // _controlVariable
            432000, // _vestingTerm
            ethers.utils.parseEther("0.000000455"), // _minimumPrice
            100000, // _maxPayout
            0, // _fee
            ethers.utils.parseEther("10000"), // _maxDebt
            0 // _initialDebt
        )

        // Donate Bond to solve transfer error for last redeem
        await D33D.mint(bond.address, ethers.utils.parseEther("0.01"))

        // Whitelist Bond contract
        await treasury.toggle(
            4, // _managing
            bond.address, // _address
            ethers.constants.AddressZero // _calculator
        )

        // Whitelist WETH
        await treasury.toggle(
            5, // _managing
            D33DUSDCAddr, // _address
            bondCalc.address // _calculator
        )

        // Bond D33DUSDC
        await D33DUSDC.approve(bond.address, ethers.constants.MaxUint256)
        await bond.deposit(
            ethers.utils.parseEther("0.001"), // _amount
            (await bond.bondPrice()).mul(101).div(100), // _maxPrice
            deployer.address // _depositor
        )

        // Redeem D33D
        await network.provider.request({method: "evm_increaseTime", params: [86400*5]}) // 5 days
        await network.provider.send("evm_mine")
        await bond.redeem(deployer.address, false)
        // console.log(ethers.utils.formatEther(await D33D.balanceOf(deployer.address)))
    })

    it("Should work with ETH", async () => {
        const [deployer] = await ethers.getSigners()

        // Deploy D33D
        const D33DFac = await ethers.getContractFactory("Token", deployer)
        const D33D = await upgrades.deployProxy(D33DFac, ["D33D", "D33D", 18])
        await D33D.mint(D33D.address, ethers.utils.parseEther("1000000"))

        // Deploy Treasury
        const treasuryFac = await ethers.getContractFactory("Treasury", deployer)
        const treasury = await upgrades.deployProxy(treasuryFac, [
            D33D.address,
            USDCAddr,
            ethers.utils.parseEther("0.1")
        ])

        // Deploy Staking
        const mockStaking = await waffle.deployMockContract(deployer, IERC20ABI)

        // Deploy BondCalc
        const bondCalcFac = await ethers.getContractFactory("BondCalc", deployer)
        const bondCalc = await upgrades.deployProxy(bondCalcFac, [
            5000, // markdownPerc_
            ETHOracleAddr // _oracle
        ])

        // Deploy BondContract
        const bondFac = await ethers.getContractFactory("BondContract", deployer)
        const bond = await upgrades.deployProxy(bondFac, [
            D33D.address, // _D33D
            WETHAddr, // _principle
            treasury.address, // _treasury
            deployer.address, // _DAO
            bondCalc.address, // _bondCalculator
            mockStaking.address, // _staking
            deployer.address, // _admin
            ethers.constants.AddressZero, // _trustedForwarderAddress
        ])

        // Donate Bond to solve transfer error for last redeem
        await D33D.mint(bond.address, ethers.utils.parseEther("0.01"))

        // Whitelist Bond contract
        await treasury.toggle(
            4, // _managing
            bond.address, // _address
            ethers.constants.AddressZero // _calculator
        )

        // Whitelist WETH
        await treasury.toggle(
            5, // _managing
            WETHAddr, // _address
            bondCalc.address // _calculator
        )

        // Initialize Bond
        await bond.initializeBondTerms(
            600, // _controlVariable
            432000, // _vestingTerm
            ethers.utils.parseEther("0.000303"), // _minimumPrice
            100000, // _maxPayout
            0, // _fee
            ethers.utils.parseEther("10000"), // _maxDebt
            0 // _initialDebt
        )

        // Bond ETH
        await bond.deposit(
            ethers.utils.parseEther("1"), // _amount
            (await bond.bondPrice()).mul(101).div(100), // _maxPrice
            deployer.address, // _depositor
            {value: ethers.utils.parseEther("1")}
        )

        // Redeem D33D
        await network.provider.request({method: "evm_increaseTime", params: [86400*5]}) // 5 days
        await network.provider.send("evm_mine")
        await bond.redeem(deployer.address, false)
        // console.log(ethers.utils.formatEther(await D33D.balanceOf(deployer.address)))
    })

    it("Should work with SAND", async () => {
        const [deployer, user] = await ethers.getSigners()

        // Deploy D33D
        const D33DFac = await ethers.getContractFactory("Token", deployer)
        const D33D = await upgrades.deployProxy(D33DFac, ["D33D", "D33D", 18])
        await D33D.mint(D33D.address, ethers.utils.parseEther("1000000"))

        // Deploy Treasury
        const treasuryFac = await ethers.getContractFactory("Treasury", deployer)
        const treasury = await upgrades.deployProxy(treasuryFac, [
            D33D.address,
            USDCAddr,
            ethers.utils.parseEther("0.1")
        ])

        // Deploy BondCalc
        const bondCalcFac = await ethers.getContractFactory("BondCalc", deployer)
        const bondCalc = await upgrades.deployProxy(bondCalcFac, [
            5000, // markdownPerc_
            SANDOracleAddr // _oracle
        ])

        // Deploy Staking
        const mockStaking = await waffle.deployMockContract(deployer, IERC20ABI)

        // Deploy BondContract
        const bondFac = await ethers.getContractFactory("BondContract", deployer)
        const bond = await upgrades.deployProxy(bondFac, [
            D33D.address, // _D33D
            SANDAddr, // _principle
            treasury.address, // _treasury
            deployer.address, // _DAO
            bondCalc.address, // _bondCalculator
            mockStaking.address, // _staking
            deployer.address, // _admin
            ethers.constants.AddressZero, // _trustedForwarderAddress
        ])

        // Donate Bond to solve transfer error for last redeem
        await D33D.mint(bond.address, ethers.utils.parseEther("0.01"))

        // Whitelist Bond contract
        await treasury.toggle(
            4, // _managing
            bond.address, // _address
            ethers.constants.AddressZero // _calculator
        )

        // Whitelist SAND
        await treasury.toggle(
            5, // _managing
            SANDAddr, // _address
            bondCalc.address // _calculator
        )

        // Initialize Bond
        await bond.initializeBondTerms(
            600, // _controlVariable
            432000, // _vestingTerm
            ethers.utils.parseEther("0.284"), // _minimumPrice
            100000, // _maxPayout
            0, // _fee
            ethers.utils.parseEther("10000"), // _maxDebt
            0 // _initialDebt
        )

        // Bond SAND
        const SAND = new ethers.Contract(SANDAddr, IERC20ABI, deployer)
        await SAND.approve(bond.address, ethers.constants.MaxUint256)
        await bond.deposit(
            ethers.utils.parseEther("1000"), // _amount
            (await bond.bondPrice()).mul(101).div(100), // _maxPrice
            deployer.address // _depositor
        )

        // Redeem D33D
        await network.provider.request({method: "evm_increaseTime", params: [86400*5]}) // 5 days
        await network.provider.send("evm_mine")
        await bond.redeem(deployer.address, false)
        // console.log(ethers.utils.form/atEther(await D33D.balanceOf(deployer.address)))
    })

    it("Should work with USDC", async () => {
        const [deployer] = await ethers.getSigners()

        // Deploy D33D
        const D33DFac = await ethers.getContractFactory("Token", deployer)
        const D33D = await upgrades.deployProxy(D33DFac, ["D33D", "D33D", 18])
        await D33D.mint(D33D.address, ethers.utils.parseEther("1000000"))

        // Deploy Treasury
        const treasuryFac = await ethers.getContractFactory("Treasury", deployer)
        const treasury = await upgrades.deployProxy(treasuryFac, [
            D33D.address,
            USDCAddr,
            ethers.utils.parseEther("0.1")
        ])

        // Deploy Staking
        const mockStaking = await waffle.deployMockContract(deployer, IERC20ABI)

        // Deploy BondContract
        const bondFac = await ethers.getContractFactory("BondContract", deployer)
        const bond = await upgrades.deployProxy(bondFac, [
            D33D.address, // _D33D
            USDCAddr, // _principle
            treasury.address, // _treasury
            deployer.address, // _DAO
            ethers.constants.AddressZero, // _bondCalculator
            mockStaking.address, // _staking
            deployer.address, // _admin
            ethers.constants.AddressZero, // _trustedForwarderAddress
        ])

        // Donate Bond to solve transfer error for last redeem
        await D33D.mint(bond.address, ethers.utils.parseEther("0.01"))

        // Whitelist Bond contract
        await treasury.toggle(
            0, // _managing
            bond.address, // _address
            ethers.constants.AddressZero // _calculator
        )

        // Initialize Bond
        await bond.initializeBondTerms(
            600, // _controlVariable
            432000, // _vestingTerm
            ethers.utils.parseEther("0.909"), // _minimumPrice
            100000, // _maxPayout
            0, // _fee
            ethers.utils.parseEther("10000"), // _maxDebt
            0 // _initialDebt
        )

        // Bond USDC
        const USDC = new ethers.Contract(USDCAddr, IERC20ABI, deployer)
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
    })
})