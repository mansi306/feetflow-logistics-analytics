import pandas as pd
from sqlalchemy import create_engine

# ── MySQL Connection ──────────────────────────────────────────
engine = create_engine(
    "mysql+pymysql://root:mansi123@localhost:3306/feetflow"
)

# ── File Paths ────────────────────────────────────────────────
BASE_PATH = r"../notebooks/outputs"

# ── Safe CSV Loader ───────────────────────────────────────────
def load_csv(filename):
    path = f"{BASE_PATH}/{filename}"
    try:
        df = pd.read_csv(path)
        print(f"Loaded: {filename} | Shape: {df.shape}")
        return df
    except Exception as e:
        print(f"Error loading {filename}: {e}")
        raise

# ── Load Files ────────────────────────────────────────────────
orders = load_csv("orders_clean.csv")
drivers = load_csv("drivers_enriched.csv")
hubs = load_csv("hubs_enriched.csv")
vehicles = load_csv("vehicles_enriched.csv")

# ── Standardize Date Columns ─────────────────────────────────
date_cols = {
    "orders": ["Order_Date", "Actual_Delivery_Date"],
    "drivers": ["Hire_Date"],
    "vehicles": ["Purchase_Date"]
}

for col in date_cols["orders"]:
    if col in orders.columns:
        orders[col] = pd.to_datetime(orders[col], errors="coerce")

for col in date_cols["drivers"]:
    if col in drivers.columns:
        drivers[col] = pd.to_datetime(drivers[col], errors="coerce")

for col in date_cols["vehicles"]:
    if col in vehicles.columns:
        vehicles[col] = pd.to_datetime(vehicles[col], errors="coerce")

# ── Boolean Cleanup ───────────────────────────────────────────
bool_cols = ["Is_Delayed", "Is_On_Time"]

for col in bool_cols:
    if col in orders.columns:
        orders[col] = orders[col].astype(int)

# ── Push to MySQL ─────────────────────────────────────────────
orders.to_sql("orders", engine, if_exists="replace", index=False)
drivers.to_sql("drivers", engine, if_exists="replace", index=False)
hubs.to_sql("hubs", engine, if_exists="replace", index=False)
vehicles.to_sql("vehicles", engine, if_exists="replace", index=False)

print("\nAll 4 tables loaded successfully into MySQL ✓")