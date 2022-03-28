const { ethers, upgrades } = require("hardhat")
const { expect } = require("chai")
const IERC20ABI = require("../abis/IERC20ABI.json")
const routerABI = require("../abis/routerABI.json")

const DVDAddr = "0x77dcE26c03a9B833fc2D7C31C22Da4f42e9d9582"
const USDCAddr = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
const WETHAddr = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
const sRouterAddr = "0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F"
const uRouterAddr = "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D"

describe("USM", () => {
    it("Should work", async () => {
        const [deployer, user] = await ethers.getSigners()

        // Deploy USM
        const USMFac = await ethers.getContractFactory("USM", deployer)
        const USM = await upgrades.deployProxy(USMFac)
        await expect(USM.mint(deployer.address, 0)).to.be.revertedWith("Mintable: caller is not the minter")
        await USM.setMinter(deployer.address)
        expect(await USM.minter()).to.eq(deployer.address)

        // USM contract coverage
        await USM.mint(deployer.address, ethers.utils.parseEther("5001"))
        await USM.addWhiltelist(deployer.address)
        await USM.transfer(user.address, ethers.utils.parseEther("5001"))
        await expect(USM.connect(user).transfer(user.address, ethers.utils.parseEther("5001"))).to.be.revertedWith("Transfer amount is too large")
        await USM.connect(user).approve(user.address, ethers.constants.MaxUint256)
        await expect(USM.transferFrom(user.address, user.address, ethers.utils.parseEther("5001"))).to.be.revertedWith("Transfer amount is too large")
        await USM.removeWhiltelist(deployer.address)
        await USM.connect(user).transferFrom(user.address, deployer.address, ethers.utils.parseEther("4000"))
        await USM.connect(deployer).burn(ethers.utils.parseEther("1000"))
        await USM.connect(deployer).approve(deployer.address, ethers.constants.MaxUint256)
        await USM.connect(deployer).burnFrom(deployer.address, ethers.utils.parseEther("1000"))
        await USM.setTransferAmountMax(ethers.utils.parseEther("4000"))
        expect(await USM.transferAmountMax()).to.eq(ethers.utils.parseEther("4000"))

        // Get some DVD
        const router = new ethers.Contract(uRouterAddr, routerABI, deployer)
        await router.swapETHForExactTokens(
            ethers.utils.parseEther("1000"), [WETHAddr, DVDAddr], deployer.address, Math.ceil(Date.now() / 1000) + 31539000,
            {value: ethers.utils.parseEther("1")}
        )
        const DVD = new ethers.Contract(DVDAddr, IERC20ABI, deployer)

        // Deploy D33D
        const D33DFac = await ethers.getContractFactory("Token", deployer)
        const D33D = await upgrades.deployProxy(D33DFac, ["D33D", "D33D", 18])

        // Deploy USMMinter
        const USMMinterFac = await ethers.getContractFactory("USMMinter", deployer)
        await expect(upgrades.deployProxy(USMMinterFac, [ // USMMinter contract coverage
            ethers.constants.AddressZero, // _USM
            DVD.address, // _dvd
            D33D.address, // _d33d
            WETHAddr, // _weth
            USDCAddr, // _usdc
            uRouterAddr, // _dvdRouter
            sRouterAddr, // _d33dRouter
            ethers.constants.AddressZero // _biconomyForwarder
        ])).to.be.reverted
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
        await USM.setMinter(USMMinter.address)

        // Clear out deployer's USM
        await USM.connect(deployer).transfer(user.address, USM.balanceOf(deployer.address))

        // Mint USM with DVD
        await DVD.approve(USMMinter.address, ethers.constants.MaxUint256)
        await USMMinter.setMintAmountMax(ethers.utils.parseEther("1"))
        await expect(USMMinter.mintWithDvd(ethers.utils.parseEther("1000"), deployer.address)).to.be.revertedWith("Mint amount is too large")
        await USMMinter.setMintAmountMax(ethers.utils.parseEther("5000"))
        await USMMinter.mintWithDvd(ethers.utils.parseEther("1000"), deployer.address)
        // console.log(ethers.utils.formatEther(await USM.balanceOf(deployer.address)))

        // USMMinter contract coverage
        await USM.transfer(user.address, USM.balanceOf(deployer.address))
        await USMMinter.collectFee()
        expect(await USM.balanceOf(deployer.address)).gt(0)
        await USM.transfer(user.address, USM.balanceOf(deployer.address))
        await USMMinter.mint(deployer.address, ethers.utils.parseEther("10"))
        expect(await USM.balanceOf(deployer.address)).to.eq(ethers.utils.parseEther("10"))
        expect(await USMMinter.versionRecipient()).to.eq("1")
        await USMMinter.setBiconomy(user.address)
        expect(await USMMinter.trustedForwarder()).to.eq(user.address)
        await expect(USMMinter.setUSM(ethers.constants.AddressZero)).to.be.reverted
        await USMMinter.setUSM(user.address)
        expect(await USMMinter.USM()).to.eq(user.address)
        await USMMinter.setDvdLpSwapRouter(user.address)
        expect(await USMMinter.routers(DVDAddr)).to.eq(user.address)
        await USMMinter.setD33dLpSwapRouter(user.address)
        expect(await USMMinter.routers(D33D.address)).to.eq(user.address)
        await expect(USMMinter.setDVD(ethers.constants.AddressZero)).to.be.reverted
        await USMMinter.setDVD(user.address)
        expect(await USMMinter.DVD()).to.eq(user.address)
        await expect(USMMinter.setD33D(ethers.constants.AddressZero)).to.be.reverted
        await USMMinter.setD33D(user.address)
        expect(await USMMinter.D33D()).to.eq(user.address)
        await expect(USMMinter.setWETH(ethers.constants.AddressZero)).to.be.reverted
        await USMMinter.setWETH(user.address)
        expect(await USMMinter.WETH()).to.eq(user.address)
        await expect(USMMinter.setUSDC(ethers.constants.AddressZero)).to.be.reverted
        await USMMinter.setUSDC(user.address)
        expect(await USMMinter.USDC()).to.eq(user.address)
        await expect(USMMinter.setMintFee(1001)).to.be.revertedWith("fee can't be higher than 1000 bps")
        await USMMinter.setMintFee(1000)
        expect(await USMMinter.mintFeeBasisPoints()).to.eq(1000)
    })
})
