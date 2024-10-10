import aiohttp

from app import app, scheduler, logger

from config import ZHUQUE_COOKIE, ZHUQUE_CSRF

last_price = 0
cookie_headers = {
    "Cookie": ZHUQUE_COOKIE,
    "X-Csrf-Token": ZHUQUE_CSRF,
}

url = "https://zhuque.in/api/transaction/list?page=1&size=1&type=1&onlyUnsold=true&onlyRelated=false"


async def fetch_data():
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(url, headers=cookie_headers) as response:
                if response.status == 200:
                    json_response = await response.json()
                    data = json_response["data"]["transactions"][0]
                    return data
                else:
                    logger.error(f"Request failed with status {response.status}")
                    return None
    except Exception as e:
        logger.error("fetch_data获取失败")


async def buy(id: int):
    try:
        async with aiohttp.ClientSession() as session:
            async with session.post(
                "https://zhuque.in/api/transaction/exchange",
                headers=cookie_headers,
                data={"id": id},
            ) as response:
                if response.status == 200:
                    return True
                else:
                    logger.error(f"Request failed with status {response.status}")
                    return None
    except Exception as e:
        logger.error("fetch_data获取失败")


async def schedule_transaction():
    global last_price
    data = await fetch_data()
    if not data:
        return False
    bonus = data["bonus"] / 10000
    upload = data["upload"] / 1024 / 1024 / 1024
    price = upload / bonus
    name = data["seller"]["username"]
    id = data["id"]
    if price != last_price:
        if price < 70:
            if await buy(id):
                await app.send_message(
                    -1002114116260,
                    f"执行自动购买: **{price:.2f}** GB/万灵石\n卖方：{name}\n花费上传：{upload:.2f} G\n获得零食：{bonus:.2f} 万",
                )
        logger.info(
            f"交易行最低单价变化: **{price:.2f}** GB/万灵石\n卖方：{name}\n花费上传：{upload:.2f} G\n获得零食：{bonus:.2f} 万"
        )
        last_price = price
    return True


scheduler.add_job(schedule_transaction, "cron", hour="*", minute="*", second="*/3")

if __name__ == "__main__":
    from asyncio import run

    run(schedule_transaction)
