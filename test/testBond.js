const { ethers, upgrades, waffle } = require("hardhat")
const { expect } = require("chai")
const IERC20ABI = require("../abis/IERC20ABI.json")
const routerABI = require("../abis/routerABI.json")
const factoryABI = require("../abis/factoryABI.json")

const USDCAddr = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
const USDTAddr = "0xdAC17F958D2ee523a2206206994597C13D831ec7"
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
            ethers.utils.parseUnits("210000", 6), [WETHAddr, USDCAddr], deployer.address, Math.ceil(Date.now() / 1000),
            {value: ethers.utils.parseEther("100")}
        )

        // Get some SAND
        const uRouter = new ethers.Contract(uRouterAddr, routerABI, deployer)
        await uRouter.swapETHForExactTokens(
            ethers.utils.parseEther("1000"), [WETHAddr, SANDAddr], deployer.address, Math.ceil(Date.now() / 1000),
            {value: ethers.utils.parseEther("10")}
        )
    })

    it("Should work with NFT", async () => {
        const [deployer, admin, nftOracle, anon] = await ethers.getSigners()

        // Deploy D33D
        const D33DFac = await ethers.getContractFactory("Token", deployer)
        const D33D = await upgrades.deployProxy(D33DFac, ["D33D", "D33D", 18])
        await D33D.mint(D33D.address, ethers.utils.parseEther("10000"))

        // Deploy NFT
        const nftFac = await ethers.getContractFactory("NFT", deployer)
        const nft = await upgrades.deployProxy(nftFac, ["NFT", "NFT"])
        await nft.mint(deployer.address)
        await nft.mint(deployer.address)

        // Deploy Treasury
        const treasuryFac = await ethers.getContractFactory("Treasury", deployer)
        const treasury = await upgrades.deployProxy(treasuryFac, [
            D33D.address,
            USDCAddr,
            ethers.utils.parseEther("0.1")
        ])

        // Deploy BondCalc
        const bondCalcFac = await ethers.getContractFactory("BondCalcNFT", deployer)
        const bondCalc = await upgrades.deployProxy(bondCalcFac, [
            5000, // markdownPerc_
            nftOracle.address, // nftOracle_
            ETHOracleAddr // ethOracle_
        ])
        await bondCalc.setAdmin(admin.address)
        expect(await bondCalc.admin()).to.eq(admin.address)
        await expect(bondCalc.connect(anon).setPrice(ethers.utils.parseEther("2.47"))).to.be.revertedWith("Not authorized")
        await bondCalc.connect(admin).setPrice(ethers.utils.parseEther("2.47"))
        await bondCalc.connect(nftOracle).setPrice(ethers.utils.parseEther("2.47"))
        await bondCalc.connect(deployer).setPrice(ethers.utils.parseEther("2.47"))

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
            100, // _fee
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

        // Bond NFT
        await nft.approve(bond.address, 0)
        await bond.deposit(
            0, // _tokenId
            (await bond.bondPrice()).mul(101).div(100), // _maxPrice
            deployer.address // _depositor
        )

        await expect(treasury.manageNFT(nft.address, 0)).to.be.revertedWith("Not approved")
        await treasury.toggle(6, deployer.address, ethers.constants.AddressZero)
        await expect(treasury.manageNFT(nft.address, 0)).to.be.revertedWith("reserves")
        await nft.approve(bond.address, 1)
        await bond.deposit(
            1, // _tokenId
            (await bond.bondPrice()).mul(101).div(100), // _maxPrice
            deployer.address // _depositor
        )
        await treasury.manageNFT(nft.address, 0)
        expect(await nft.balanceOf(deployer.address)).to.eq(1)

        // Redeem D33D
        await network.provider.request({method: "evm_increaseTime", params: [86400*5]}) // 5 days
        await network.provider.send("evm_mine")
        await bond.redeem(deployer.address, false)
        // console.log(ethers.utils.formatEther(await D33D.balanceOf(deployer.address)))

        await bondCalc.setMarkdownPerc(6000)
        expect(await bondCalc.markdownPerc()).to.eq(6000)
        await bondCalc.setNFTOracle(deployer.address)
        expect(await bondCalc.nftOracle()).to.eq(deployer.address)
        await expect(bondCalc.requestPriceUpdate()).to.be.reverted

        await expect(treasury.depositNFT(0, USDCAddr, 0)).to.be.revertedWith("Not accepted")
        await expect(treasury.depositNFT(0, nft.address, 0)).to.be.revertedWith("Not approved")

        await treasury.auditReserves()
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

        await bondCalc.setMarkdownPerc(6000)
        expect(await bondCalc.markdownPerc()).to.eq(6000)
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

        await expect(bond.deposit(
            ethers.utils.parseEther("1"), // _amount
            (await bond.bondPrice()).mul(101).div(100), // _maxPrice
            deployer.address, // _depositor
            {value: ethers.utils.parseEther("0.1")}
        )).to.be.revertedWith("Invalid ETH")

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

        // Deploy USM
        const USMFac = await ethers.getContractFactory("Token", deployer)
        const USM = await upgrades.deployProxy(USMFac, ["USM", "USM", 18])

        // Deploy Treasury
        const treasuryFac = await ethers.getContractFactory("Treasury", deployer)
        const treasury = await upgrades.deployProxy(treasuryFac, [
            D33D.address,
            USDCAddr,
            ethers.utils.parseEther("0.1")
        ])
        await treasury.toggle(0, deployer.address, ethers.constants.AddressZero)
        const USDC = new ethers.Contract(USDCAddr, IERC20ABI, deployer)
        await USDC.approve(treasury.address, ethers.constants.MaxUint256)
        await treasury.deposit(ethers.utils.parseUnits("100000", 6), USDCAddr, ethers.utils.parseEther("1000000"))

        // Deploy BondCalc
        const bondCalcFac = await ethers.getContractFactory("BondCalc", deployer)
        const bondCalc = await upgrades.deployProxy(bondCalcFac, [
            5000, // markdownPerc_
            SANDOracleAddr // _oracle
        ])

        // Deploy Staking
        const stakingFac = await ethers.getContractFactory("Staking", deployer)
        const staking = await upgrades.deployProxy(stakingFac, [
            ethers.constants.AddressZero,
            USM.address,
            ethers.utils.parseEther("5000")
        ])

        // Deploy BondContract
        const bondFac = await ethers.getContractFactory("BondContract", deployer)
        const bond = await upgrades.deployProxy(bondFac, [
            D33D.address, // _D33D
            SANDAddr, // _principle
            treasury.address, // _treasury
            deployer.address, // _DAO
            bondCalc.address, // _bondCalculator
            staking.address, // _staking
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
        expect(await bond.pendingPayoutFor(deployer.address)).to.gt(ethers.utils.parseEther("3500"))
        await bond.redeem(deployer.address, false)
        // console.log(ethers.utils.formatEther(await D33D.balanceOf(deployer.address)))

        await bondCalc.setMarkdownPerc(6000)
        expect(await bondCalc.markdownPerc()).to.eq(6000)

        await expect(treasury.manage(SANDAddr, 0)).to.be.revertedWith("Not approved")
        await treasury.toggle(6, deployer.address, ethers.constants.AddressZero)
        await expect(treasury.manage(SANDAddr, ethers.utils.parseEther("1000"))).to.be.revertedWith("reserves")
        await treasury.manage(SANDAddr, ethers.utils.parseEther("1"))
        expect(await SAND.balanceOf(deployer.address)).to.eq(ethers.utils.parseEther("1"))

        await treasury.updateD33DPrice(ethers.utils.parseEther("1"))
        expect(await treasury.D33DPrice()).to.eq(ethers.utils.parseEther("1"))
        await treasury.auditReserves()
        await expect(treasury.deposit(0, deployer.address, 0)).to.be.revertedWith("Not accepted")
        await expect(treasury.connect(user).deposit(0, USDCAddr, 0)).to.be.revertedWith("Not approved")
        await expect(treasury.deposit(0, SANDAddr, 0)).to.be.revertedWith("Not approved")
    })

    it("Should work with USDC", async () => {
        const [deployer, user] = await ethers.getSigners()

        // Deploy D33D
        const D33DFac = await ethers.getContractFactory("Token", deployer)
        const D33D = await upgrades.deployProxy(D33DFac, ["D33D", "D33D", 18])

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

        // Create supply for D33D
        expect(await bond.debtRatio()).to.eq(0)
        await treasury.toggle(0, deployer.address, ethers.constants.AddressZero)
        const USDC = new ethers.Contract(USDCAddr, IERC20ABI, deployer)
        await USDC.approve(treasury.address, ethers.constants.MaxUint256)
        await treasury.deposit(ethers.utils.parseUnits("10000", 6), USDCAddr, ethers.utils.parseEther("100000"))

        // Donate Bond to solve transfer error for last redeem
        await D33D.mint(bond.address, ethers.utils.parseEther("0.01"))

        // Whitelist Bond contract
        await treasury.toggle(
            0, // _managing
            bond.address, // _address
            ethers.constants.AddressZero // _calculator
        )

        await expect(bond.connect(user).initializeBondTerms(
            600, // _controlVariable
            432000, // _vestingTerm
            ethers.utils.parseEther("0.909"), // _minimumPrice
            100000, // _maxPayout
            0, // _fee
            ethers.utils.parseEther("10000"), // _maxDebt
            0 // _initialDebt
        )).to.be.revertedWith("Only admin")

        // Initialize Bond
        await bond.initializeBondTerms(
            100, // _controlVariable
            432000, // _vestingTerm
            ethers.utils.parseEther("0.909"), // _minimumPrice
            100000, // _maxPayout
            100, // _fee
            ethers.utils.parseEther("10000"), // _maxDebt
            0 // _initialDebt
        )

        await expect(bond.initializeBondTerms(
            100, // _controlVariable
            432000, // _vestingTerm
            ethers.utils.parseEther("0.909"), // _minimumPrice
            100000, // _maxPayout
            0, // _fee
            ethers.utils.parseEther("10000"), // _maxDebt
            0 // _initialDebt
        )).to.be.revertedWith("Bonds must be initialized from 0")

        // Bond USDC
        await USDC.approve(bond.address, ethers.constants.MaxUint256)
        await bond.deposit(
            ethers.utils.parseUnits("1000", 6), // _amount
            (await bond.bondPrice()).mul(101).div(100), // _maxPrice
            deployer.address // _depositor
        )

        await expect(bond.setAdjustment(true, 3, 150, 0)).to.be.revertedWith("Increment too large")
        await bond.setAdjustment(true, 2, 102, 0)
        await bond.deposit(ethers.utils.parseUnits("1", 6), ethers.constants.MaxUint256, deployer.address)
        await bond.setAdjustment(false, 2, 100, 0)
        await bond.deposit(ethers.utils.parseUnits("1", 6), ethers.constants.MaxUint256, deployer.address)
        await USDC.transfer(bond.address, USDC.balanceOf(deployer.address)) // Clear out remaining USDC

        await expect(bond.deposit(0, 0, ethers.constants.AddressZero)).to.be.revertedWith("Invalid address")
        await expect(bond.deposit(0, ethers.utils.parseEther("0.9"), deployer.address)).to.be.revertedWith("Slippage limit: more than max price")
        await expect(bond.deposit(ethers.utils.parseUnits("1", 3), ethers.utils.parseEther("1"), deployer.address)).to.be.revertedWith("Bond too small")
        await bond.setBondTerms(1, 1)
        await expect(bond.deposit(ethers.utils.parseUnits("2", 6), ethers.utils.parseEther("1"), deployer.address)).to.be.revertedWith("Bond too large")
        await bond.setBondTerms(3, ethers.utils.parseEther("1"))
        await expect(bond.deposit(0, 0, deployer.address)).to.be.revertedWith("Max capacity reached")
        await expect(bond.setBondTerms(0, 129599)).to.be.revertedWith("Vesting must be longer than 36 hours")
        await bond.setBondTerms(0, 129600)
        expect((await bond.terms())[1]).to.eq(129600)
        await expect(bond.setBondTerms(2, 10001)).to.be.revertedWith("DAO fee cannot exceed payout")
        await bond.setBondTerms(2, 1000)
        expect((await bond.terms())[4]).to.eq(1000)

        // Redeem D33D
        await network.provider.request({method: "evm_increaseTime", params: [86400*2]}) // 2 days
        await network.provider.send("evm_mine")
        expect(await bond.pendingPayoutFor(deployer.address)).to.lt(ethers.utils.parseEther("440"))
        await bond.redeem(deployer.address, false)
        await network.provider.request({method: "evm_increaseTime", params: [86400*3]}) // 3 days
        await network.provider.send("evm_mine")
        await bond.redeem(deployer.address, false)
        expect(await D33D.balanceOf(deployer.address)).to.gt(ethers.utils.parseEther("1100"))

        await expect(treasury.withdraw(0, SANDAddr)).to.be.revertedWith("Not accepted")
        await expect(treasury.withdraw(0, USDCAddr)).to.be.revertedWith("Not approved")
        await treasury.toggle(1, deployer.address, ethers.constants.AddressZero)
        await D33D.approve(treasury.address, ethers.constants.MaxUint256)
        await treasury.withdraw(ethers.utils.parseUnits("1", 6), USDCAddr)
        await expect(treasury.manage(USDCAddr, 0)).to.be.revertedWith("Not approved")
        await treasury.toggle(3, deployer.address, ethers.constants.AddressZero)
        await treasury.manage(USDCAddr, ethers.utils.parseUnits("1", 6))
        expect(await USDC.balanceOf(deployer.address)).to.eq(ethers.utils.parseUnits("2", 6))

        await bond.setStaking(ethers.constants.AddressZero)
        expect(await bond.staking()).to.eq(ethers.constants.AddressZero)
        await bond.setMinimumPrice(1)
        expect((await bond.terms())[2]).to.eq(1)
        await bond.setTrustedForwarder(deployer.address)
        expect(await bond.trustedForwarder()).to.eq(deployer.address)
        expect(await bond.versionRecipient()).to.eq("1")

        expect(await bond.percentVestedFor(user.address)).to.eq(0)
        expect(await bond.debtDecay()).to.eq(await bond.totalDebt())

        await expect(treasury.editPermission(0, ethers.constants.AddressZero, true)).to.be.reverted
        await treasury.editPermission(0, deployer.address, true)
        expect(await treasury.isReserveDepositor(deployer.address)).is.true
        await treasury.editPermission(1, deployer.address, true)
        expect(await treasury.isReserveSpender(deployer.address)).is.true
        await treasury.editPermission(2, deployer.address, true)
        expect(await treasury.isReserveToken(deployer.address)).is.true
        await treasury.editPermission(3, deployer.address, true)
        expect(await treasury.isReserveManager(deployer.address)).is.true
        await treasury.editPermission(4, deployer.address, true)
        expect(await treasury.isLiquidityDepositor(deployer.address)).is.true
        await treasury.editPermission(5, deployer.address, true)
        expect(await treasury.isLiquidityToken(deployer.address)).is.true
        await treasury.editPermission(6, deployer.address, true)
        expect(await treasury.isLiquidityManager(deployer.address)).is.true
        await treasury.editPermission(7, deployer.address, true)
        expect(await treasury.isRewardManager(deployer.address)).is.true
        await treasury.editPermission(8, deployer.address, true)
        expect(await treasury.isNFTDepositor(deployer.address)).is.true
        await treasury.editPermission(9, deployer.address, true)
        expect(await treasury.isSupportedNFT(deployer.address)).is.true

        await treasury.toggle(2, USDCAddr, ethers.constants.AddressZero)
        expect(await treasury.isReserveToken(USDCAddr)).is.false
        await treasury.toggle(2, USDTAddr, ethers.constants.AddressZero)
        expect(await treasury.isReserveToken(USDTAddr)).is.true
    })
})